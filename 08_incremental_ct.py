import os
import time
from datetime import datetime
from decimal import Decimal
import pandas as pd
import pyodbc

SERVER = os.getenv("SQL_SERVER", "localhost")
SOURCE_DB = os.getenv("SOURCE_DB", "AdventureWorks2022")
TARGET_DB = "DM_Ventes_CT"


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
        # 1. Hedef veri ambarından (CT) son işlenen versiyonları al
        cur_dst.execute("SELECT TableSource, DerniereVersion FROM meta.EtatCT")
        version_dict = {row[0]: row[1] for row in cur_dst.fetchall()}

        # 2. Kaynaktan güncel CT versiyonunu al
        cur_src.execute("SELECT CHANGE_TRACKING_CURRENT_VERSION()")
        current_version = cur_src.fetchone()[0]

        lignes_lues = 0
        lignes_inserees = 0
        lignes_maj = 0

        last_v_prod = version_dict.get('Product')

        if last_v_prod is not None and last_v_prod < current_version:
            # 3. Geçerlilik (Retention) Kontrolü
            cur_src.execute("SELECT CHANGE_TRACKING_MIN_VALID_VERSION(OBJECT_ID('Production.Product'))")
            min_valid = cur_src.fetchone()[0]
            if min_valid is not None and min_valid > last_v_prod:
                raise Exception("Rétention dépassée, rechargement complet nécessaire.")

            # 4. Product Tablosundaki CT Değişikliklerini Oku
            sql_ct_prod = """
                          SELECT ct.SYS_CHANGE_OPERATION, ct.ProductID, p.Name, p.ProductSubcategoryID, p.ListPrice
                          FROM CHANGETABLE(CHANGES Production.Product, ?) AS ct
                                   LEFT JOIN Production.Product AS p ON ct.ProductID = p.ProductID \
                          """
            cur_src.execute(sql_ct_prod, (last_v_prod,))
            rows = cur_src.fetchall()
            lignes_lues += len(rows)

            for row in rows:
                op, p_id, p_name, p_subcat, p_price = row
                change_time = datetime.now()  # CT değişiklik saatini vermez, yükleme anı kullanılır

                if op in ('U', 'I') and p_name is not None:
                    # SCD 1 (İsim Düzeltme)
                    cur_dst.execute("UPDATE dm.DimProduit SET Nom = ? WHERE ProductID = ?", (p_name, p_id))
                    lignes_maj += cur_dst.rowcount

                    # SCD 2 (Fiyat / Kategori) - Aktif kaydı bul
                    cur_dst.execute("""
                                    SELECT CleProduit, CodeProduit, SousCategorie, Categorie, PrixCatalogue
                                    FROM dm.DimProduit
                                    WHERE ProductID = ?
                                      AND EstCourant = 1
                                    """, (p_id,))
                    current = cur_dst.fetchone()

                    if current:
                        cle, code, cur_subcat, cur_cat, cur_price = current

                        # Yeni kategori/alt kategori adlarını çek
                        new_subcat = 'Inconnu'
                        new_cat = 'Inconnu'
                        if p_subcat:
                            cur_src.execute(
                                "SELECT Name, ProductCategoryID FROM Production.ProductSubcategory WHERE ProductSubcategoryID = ?",
                                (p_subcat,))
                            sc_data = cur_src.fetchone()
                            if sc_data:
                                new_subcat = sc_data[0]
                                cur_src.execute(
                                    "SELECT Name FROM Production.ProductCategory WHERE ProductCategoryID = ?",
                                    (sc_data[1],))
                                cat_data = cur_src.fetchone()
                                if cat_data: new_cat = cat_data[0]

                        # Fiyat veya Kategori değişmişse yeni satır ekle
                        if float(cur_price) != float(p_price if p_price else 0) or cur_subcat != new_subcat:
                            cur_dst.execute("UPDATE dm.DimProduit SET DateFin = ?, EstCourant = 0 WHERE CleProduit = ?",
                                            (change_time, cle))
                            cur_dst.execute("""
                                            INSERT INTO dm.DimProduit (ProductID, CodeProduit, Nom, SousCategorie,
                                                                       Categorie, PrixCatalogue, DateDebut, DateFin,
                                                                       EstCourant)
                                            VALUES (?, ?, ?, ?, ?, ?, ?, NULL, 1)
                                            """, (p_id, code, p_name, new_subcat, new_cat, p_price, change_time))
                            lignes_inserees += 1

        # 5. Versiyon Numarasını Güncelle
        if current_version:
            cur_dst.execute(
                "UPDATE meta.EtatCT SET DerniereVersion = ?, DateMaj = ? WHERE TableSource IN ('Product', 'SalesOrderHeader', 'SalesOrderDetail')",
                (current_version, datetime.now()))

        # 6. Log Kaydı
        fin = datetime.now()
        duree = time.perf_counter() - t0
        msg = f"Chargement incrémental CT terminé en {duree:.2f}s"
        cur_dst.execute("""
                        INSERT INTO meta.JournalChargement (Methode, Debut, Fin, LignesLues, LignesInserees,
                                                            LignesMisesAJour, LignesSupprimees, LignesRejetees, Statut,
                                                            Message)
                        VALUES (?, ?, ?, ?, ?, ?, 0, 0, 'SUCCES', ?)
                        """, ("CT", debut, fin, lignes_lues, lignes_inserees, lignes_maj, msg))

        conn_dst.commit()
        print(msg)

    except Exception as exc:
        conn_dst.rollback()
        cur_dst.execute("""
                        INSERT INTO meta.JournalChargement (Methode, Debut, Fin, LignesLues, LignesInserees,
                                                            LignesMisesAJour, LignesSupprimees, LignesRejetees, Statut,
                                                            Message)
                        VALUES ('CT', ?, ?, 0, 0, 0, 0, 0, 'ERREUR', ?)
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