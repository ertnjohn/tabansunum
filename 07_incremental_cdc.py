import os
import time
from datetime import datetime
from decimal import Decimal, ROUND_HALF_UP
import pandas as pd
import pyodbc

SERVER = os.getenv("SQL_SERVER", "localhost")
SOURCE_DB = os.getenv("SOURCE_DB", "AdventureWorks2022")
TARGET_DB = "DM_Ventes_CDC"


def get_connection(database):
    conn_str = (
        f"DRIVER={{ODBC Driver 18 for SQL Server}};"
        f"SERVER={SERVER};"
        f"DATABASE={database};"
        f"Trusted_Connection=yes;"
        f"TrustServerCertificate=yes;"
    )
    return pyodbc.connect(conn_str, autocommit=False)


def main():
    t0 = time.perf_counter()
    debut = datetime.now()
    conn_src = get_connection(SOURCE_DB)
    conn_dst = get_connection(TARGET_DB)
    cur_src = conn_src.cursor()
    cur_dst = conn_dst.cursor()

    try:
        # 1. Hedef veri ambarından son işlenen LSN'leri al
        cur_dst.execute("SELECT TableSource, DernierLSN FROM meta.EtatCDC")
        lsn_dict = {row[0]: row[1] for row in cur_dst.fetchall()}

        # 2. Kaynaktan anlık maksimum LSN'i al
        cur_src.execute("SELECT sys.fn_cdc_get_max_lsn()")
        max_lsn = cur_src.fetchone()[0]

        lignes_lues = 0
        lignes_inserees = 0
        lignes_maj = 0
        lignes_supprimees = 0

        # --- PRODUCT (SCD 1 & SCD 2) İŞLEMLERİ ---
        last_lsn_prod = lsn_dict.get('Product')
        if last_lsn_prod and last_lsn_prod < max_lsn:
            sql_prod = """
                DECLARE @from_lsn binary(10) = sys.fn_cdc_increment_lsn(?);
                DECLARE @to_lsn binary(10) = ?;
                IF @from_lsn <= @to_lsn
                BEGIN
                    SELECT __$operation, ProductID, Name, ProductSubcategoryID, ListPrice, 
                           sys.fn_cdc_map_lsn_to_time(__$start_lsn) AS ChangeTime
                    FROM cdc.fn_cdc_get_net_changes_Production_Product(@from_lsn, @to_lsn, 'all')
                END
            """
            cur_src.execute(sql_prod, (last_lsn_prod, max_lsn))
            rows = cur_src.fetchall()
            lignes_lues += len(rows)

            for row in rows:
                op, p_id, p_name, p_subcat, p_price, change_time = row

                # SCD 1: İsim değişikliği (Eski versiyonlar dahil her yeri günceller)
                if op in (3, 4):
                    cur_dst.execute("""
                                    UPDATE dm.DimProduit
                                    SET Nom = ?
                                    WHERE ProductID = ?
                                    """, (p_name, p_id))
                    lignes_maj += cur_dst.rowcount

                    # SCD 2: Fiyat veya Kategori değişikliği (Eski versiyonu kapat, yeni versiyon aç)
                    # Basitleştirilmiş SCD2 mantığı: Aktif versiyonu bul, değişiklik varsa kapat ve yeni ekle
                    cur_dst.execute("""
                                    SELECT CleProduit, CodeProduit, SousCategorie, Categorie, PrixCatalogue
                                    FROM dm.DimProduit
                                    WHERE ProductID = ?
                                      AND EstCourant = 1
                                    """, (p_id,))
                    current = cur_dst.fetchone()

                    if current:
                        cle, code, cur_subcat, cur_cat, cur_price = current
                        # Yeni alt kategorinin adını kaynaktan bul
                        cur_src.execute(
                            "SELECT Name, ProductCategoryID FROM Production.ProductSubcategory WHERE ProductSubcategoryID = ?",
                            (p_subcat,))
                        subcat_data = cur_src.fetchone()
                        new_subcat = subcat_data[0] if subcat_data else 'Inconnu'
                        cat_id = subcat_data[1] if subcat_data else None

                        new_cat = 'Inconnu'
                        if cat_id:
                            cur_src.execute("SELECT Name FROM Production.ProductCategory WHERE ProductCategoryID = ?",
                                            (cat_id,))
                            cat_data = cur_src.fetchone()
                            new_cat = cat_data[0] if cat_data else 'Inconnu'

                        # Fiyat veya alt kategori değiştiyse yeni SCD2 kaydı aç
                        if float(cur_price) != float(p_price) or cur_subcat != new_subcat:
                            cur_dst.execute("UPDATE dm.DimProduit SET DateFin = ?, EstCourant = 0 WHERE CleProduit = ?",
                                            (change_time, cle))
                            cur_dst.execute("""
                                            INSERT INTO dm.DimProduit (ProductID, CodeProduit, Nom, SousCategorie,
                                                                       Categorie, PrixCatalogue, DateDebut, DateFin,
                                                                       EstCourant)
                                            VALUES (?, ?, ?, ?, ?, ?, ?, NULL, 1)
                                            """, (p_id, code, p_name, new_subcat, new_cat, p_price, change_time))
                            lignes_inserees += 1

        # LSN Güncelleme
        if max_lsn:
            cur_dst.execute(
                "UPDATE meta.EtatCDC SET DernierLSN = ?, DateMaj = ? WHERE TableSource IN ('Product', 'SalesOrderHeader', 'SalesOrderDetail')",
                (max_lsn, datetime.now()))

        # Log kaydı (meta.JournalChargement)
        fin = datetime.now()
        duree = time.perf_counter() - t0
        msg = f"Chargement incrémental CDC terminé en {duree:.2f}s"
        cur_dst.execute("""
                        INSERT INTO meta.JournalChargement (Methode, Debut, Fin, LignesLues, LignesInserees,
                                                            LignesMisesAJour, LignesSupprimees, LignesRejetees, Statut,
                                                            Message)
                        VALUES (?, ?, ?, ?, ?, ?, ?, 0, 'SUCCES', ?)
                        """, ("CDC", debut, fin, lignes_lues, lignes_inserees, lignes_maj, lignes_supprimees, msg))

        conn_dst.commit()
        print(msg)

    except Exception as exc:
        conn_dst.rollback()
        cur_dst.execute("""
                        INSERT INTO meta.JournalChargement (Methode, Debut, Fin, LignesLues, LignesInserees,
                                                            LignesMisesAJour, LignesSupprimees, LignesRejetees, Statut,
                                                            Message)
                        VALUES ('CDC', ?, ?, 0, 0, 0, 0, 0, 'ERREUR', ?)
                        """, (debut, datetime.now(), str(exc)[:4000]))
        conn_dst.commit()
        raise
    finally:
        cur_src.close()
        cur_dst.close()
        conn_src.close()
        conn_dst.close()


if __name__ == "__main__":
    main()