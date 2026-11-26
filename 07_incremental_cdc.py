import os
import time
from datetime import datetime
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


def get_category_names(cur_src, subcat_id):
    if not subcat_id:
        return "Inconnu", "Inconnu"
    cur_src.execute(
        "SELECT Name, ProductCategoryID FROM Production.ProductSubcategory WHERE ProductSubcategoryID = ?",
        (subcat_id,),
    )
    subcat_data = cur_src.fetchone()
    if not subcat_data:
        return "Inconnu", "Inconnu"
    new_subcat, cat_id = subcat_data[0], subcat_data[1]
    new_cat = "Inconnu"
    if cat_id:
        cur_src.execute(
            "SELECT Name FROM Production.ProductCategory WHERE ProductCategoryID = ?",
            (cat_id,),
        )
        cat_data = cur_src.fetchone()
        if cat_data:
            new_cat = cat_data[0]
    return new_subcat, new_cat


def main():
    t0 = time.perf_counter()
    debut = datetime.now()
    conn_src = get_connection(SOURCE_DB)
    conn_dst = get_connection(TARGET_DB)
    cur_src = conn_src.cursor()
    cur_dst = conn_dst.cursor()

    try:
        cur_dst.execute("SELECT TableSource, DernierLSN FROM meta.EtatCDC")
        lsn_dict = {row[0]: row[1] for row in cur_dst.fetchall()}

        cur_src.execute("SELECT sys.fn_cdc_get_max_lsn()")
        max_lsn = cur_src.fetchone()[0]

        lignes_lues = 0
        lignes_inserees = 0
        lignes_maj = 0
        lignes_supprimees = 0

        last_lsn_prod = lsn_dict.get("Product")
        if last_lsn_prod and max_lsn and last_lsn_prod < max_lsn:
            sql_prod = """
                DECLARE @from_lsn binary(10) = sys.fn_cdc_increment_lsn(?);
                DECLARE @to_lsn binary(10) = ?;
                IF @from_lsn <= @to_lsn
                BEGIN
                    SELECT __$operation, ProductID, ProductNumber, Name, ProductSubcategoryID, ListPrice,
                           sys.fn_cdc_map_lsn_to_time(__$start_lsn) AS ChangeTime
                    FROM cdc.fn_cdc_get_all_changes_Production_Product(@from_lsn, @to_lsn, N'all')
                    ORDER BY __$start_lsn, __$seqval
                END
            """
            cur_src.execute(sql_prod, (last_lsn_prod, max_lsn))
            rows = cur_src.fetchall()
            lignes_lues += len(rows)

            for row in rows:
                op, p_id, p_num, p_name, p_subcat, p_price, change_time = row

                if op == 2:
                    new_subcat, new_cat = get_category_names(cur_src, p_subcat)
                    cur_dst.execute(
                        """
                        INSERT INTO dm.DimProduit (ProductID, CodeProduit, Nom, SousCategorie,
                                                   Categorie, PrixCatalogue, DateDebut, DateFin, EstCourant)
                        VALUES (?, ?, ?, ?, ?, ?, ?, NULL, 1)
                        """,
                        (p_id, p_num, p_name, new_subcat, new_cat, p_price, change_time),
                    )
                    lignes_inserees += 1

                elif op == 4:
                    cur_dst.execute(
                        "UPDATE dm.DimProduit SET Nom = ? WHERE ProductID = ? AND Nom <> ?",
                        (p_name, p_id, p_name),
                    )
                    lignes_maj += cur_dst.rowcount

                    cur_dst.execute(
                        """
                        SELECT CleProduit, CodeProduit, SousCategorie, Categorie, PrixCatalogue
                        FROM dm.DimProduit
                        WHERE ProductID = ? AND EstCourant = 1
                        """,
                        (p_id,),
                    )
                    current = cur_dst.fetchone()

                    if current:
                        cle, code, cur_subcat, cur_cat, cur_price = current
                        new_subcat, new_cat = get_category_names(cur_src, p_subcat)

                        if float(cur_price) != float(p_price) or cur_subcat != new_subcat:
                            cur_dst.execute(
                                "UPDATE dm.DimProduit SET DateFin = ?, EstCourant = 0 WHERE CleProduit = ?",
                                (change_time, cle),
                            )
                            cur_dst.execute(
                                """
                                INSERT INTO dm.DimProduit (ProductID, CodeProduit, Nom, SousCategorie,
                                                           Categorie, PrixCatalogue, DateDebut, DateFin, EstCourant)
                                VALUES (?, ?, ?, ?, ?, ?, ?, NULL, 1)
                                """,
                                (p_id, code, p_name, new_subcat, new_cat, p_price, change_time),
                            )
                            lignes_inserees += 1

        last_lsn_detail = lsn_dict.get("SalesOrderDetail")
        if last_lsn_detail and max_lsn and last_lsn_detail < max_lsn:
            sql_detail = """
                DECLARE @from_lsn binary(10) = sys.fn_cdc_increment_lsn(?);
                DECLARE @to_lsn binary(10) = ?;
                IF @from_lsn <= @to_lsn
                BEGIN
                    SELECT __$operation, SalesOrderID, SalesOrderDetailID, OrderQty,
                           ProductID, UnitPrice, UnitPriceDiscount
                    FROM cdc.fn_cdc_get_all_changes_Sales_SalesOrderDetail(@from_lsn, @to_lsn, N'all')
                    ORDER BY __$start_lsn, __$seqval
                END
            """
            cur_src.execute(sql_detail, (last_lsn_detail, max_lsn))
            detail_rows = cur_src.fetchall()
            lignes_lues += len(detail_rows)

            for row in detail_rows:
                op, order_id, detail_id, qty, p_id, unit_price, discount = row
                montant = round(float(qty) * float(unit_price) * (1.0 - float(discount)), 2)

                if op == 1:
                    cur_dst.execute(
                        "DELETE FROM dm.FaitVente WHERE NumCommande = ? AND NumLigne = ?",
                        (order_id, detail_id),
                    )
                    lignes_supprimees += cur_dst.rowcount

                elif op == 2:
                    cur_src.execute(
                        "SELECT OrderDate FROM Sales.SalesOrderHeader WHERE SalesOrderID = ?",
                        (order_id,),
                    )
                    hdr = cur_src.fetchone()
                    if not hdr:
                        continue
                    order_date = hdr[0]
                    cle_date = int(order_date.strftime("%Y%m%d"))

                    cur_dst.execute(
                        """
                        SELECT TOP (1) CleProduit
                        FROM dm.DimProduit
                        WHERE ProductID = ?
                          AND DateDebut <= ?
                          AND (DateFin IS NULL OR ? < DateFin)
                        ORDER BY DateDebut DESC
                        """,
                        (p_id, order_date, order_date),
                    )
                    prod_row = cur_dst.fetchone()
                    if not prod_row:
                        cur_dst.execute(
                            "SELECT TOP (1) CleProduit FROM dm.DimProduit WHERE ProductID = ? ORDER BY DateDebut ASC",
                            (p_id,),
                        )
                        prod_row = cur_dst.fetchone()
                    if not prod_row:
                        continue

                    cur_dst.execute(
                        """
                        INSERT INTO dm.FaitVente (NumCommande, NumLigne, CleDate, CleProduit,
                                                  Quantite, PrixUnitaire, Montant)
                        VALUES (?, ?, ?, ?, ?, ?, ?)
                        """,
                        (order_id, detail_id, cle_date, prod_row[0], qty, unit_price, montant),
                    )
                    lignes_inserees += 1

                elif op == 4:
                    cur_dst.execute(
                        """
                        UPDATE dm.FaitVente
                        SET Quantite = ?, PrixUnitaire = ?, Montant = ?
                        WHERE NumCommande = ? AND NumLigne = ?
                        """,
                        (qty, unit_price, montant, order_id, detail_id),
                    )
                    lignes_maj += cur_dst.rowcount

        if max_lsn:
            cur_dst.execute(
                "UPDATE meta.EtatCDC SET DernierLSN = ?, DateMaj = ? WHERE TableSource IN ('Product', 'SalesOrderHeader', 'SalesOrderDetail')",
                (max_lsn, datetime.now()),
            )

        fin = datetime.now()
        duree = time.perf_counter() - t0
        msg = f"Chargement incrémental CDC terminé en {duree:.2f}s"
        cur_dst.execute(
            """
            INSERT INTO meta.JournalChargement (Methode, Debut, Fin, LignesLues, LignesInserees,
                                                LignesMisesAJour, LignesSupprimees, LignesRejetees, Statut, Message)
            VALUES (?, ?, ?, ?, ?, ?, ?, 0, 'SUCCES', ?)
            """,
            ("CDC", debut, fin, lignes_lues, lignes_inserees, lignes_maj, lignes_supprimees, msg),
        )

        conn_dst.commit()
        print(msg)

    except Exception as exc:
        conn_dst.rollback()
        cur_dst.execute(
            """
            INSERT INTO meta.JournalChargement (Methode, Debut, Fin, LignesLues, LignesInserees,
                                                LignesMisesAJour, LignesSupprimees, LignesRejetees, Statut, Message)
            VALUES ('CDC', ?, ?, 0, 0, 0, 0, 0, 'ERREUR', ?)
            """,
            (debut, datetime.now(), str(exc)[:4000]),
        )
        conn_dst.commit()
        raise
    finally:
        cur_src.close()
        cur_dst.close()
        conn_src.close()
        conn_dst.close()


if __name__ == "__main__":
    main()