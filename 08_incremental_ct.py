import os
import time
from datetime import datetime
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


def get_category_names(cur_src, subcat_id):
    if not subcat_id:
        return "Inconnu", "Inconnu"
    cur_src.execute(
        "SELECT Name, ProductCategoryID FROM Production.ProductSubcategory WHERE ProductSubcategoryID = ?",
        (subcat_id,),
    )
    sc_data = cur_src.fetchone()
    if not sc_data:
        return "Inconnu", "Inconnu"
    new_subcat, cat_id = sc_data[0], sc_data[1]
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
        cur_dst.execute("SELECT TableSource, DerniereVersion FROM meta.EtatCT")
        version_dict = {row[0]: row[1] for row in cur_dst.fetchall()}

        cur_src.execute("SELECT CHANGE_TRACKING_CURRENT_VERSION()")
        current_version = cur_src.fetchone()[0]

        lignes_lues = 0
        lignes_inserees = 0
        lignes_maj = 0
        lignes_supprimees = 0

        last_v_prod = version_dict.get("Product")
        if last_v_prod is not None and current_version is not None and last_v_prod < current_version:
            cur_src.execute("SELECT CHANGE_TRACKING_MIN_VALID_VERSION(OBJECT_ID('Production.Product'))")
            min_valid = cur_src.fetchone()[0]
            if min_valid is not None and min_valid > last_v_prod:
                raise Exception("Rétention dépassée pour Production.Product, rechargement complet nécessaire.")

            sql_ct_prod = """
                SELECT ct.SYS_CHANGE_OPERATION, ct.ProductID, p.ProductNumber,
                       p.Name, p.ProductSubcategoryID, p.ListPrice
                FROM CHANGETABLE(CHANGES Production.Product, ?) AS ct
                LEFT JOIN Production.Product AS p ON ct.ProductID = p.ProductID
            """
            cur_src.execute(sql_ct_prod, (last_v_prod,))
            rows = cur_src.fetchall()
            lignes_lues += len(rows)

            for row in rows:
                op, p_id, p_num, p_name, p_subcat, p_price = row
                change_time = datetime.now()

                if op == "I" and p_name is not None:
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

                elif op == "U" and p_name is not None:
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

                        if float(cur_price) != float(p_price if p_price else 0) or cur_subcat != new_subcat:
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

        last_v_detail = version_dict.get("SalesOrderDetail")
        if last_v_detail is not None and current_version is not None and last_v_detail < current_version:
            cur_src.execute("SELECT CHANGE_TRACKING_MIN_VALID_VERSION(OBJECT_ID('Sales.SalesOrderDetail'))")
            min_valid_d = cur_src.fetchone()[0]
            if min_valid_d is not None and min_valid_d > last_v_detail:
                raise Exception("Rétention dépassée pour Sales.SalesOrderDetail, rechargement complet nécessaire.")

            sql_ct_detail = """
                SELECT ct.SYS_CHANGE_OPERATION, ct.SalesOrderID, ct.SalesOrderDetailID,
                       d.OrderQty, d.ProductID, d.UnitPrice, d.UnitPriceDiscount
                FROM CHANGETABLE(CHANGES Sales.SalesOrderDetail, ?) AS ct
                LEFT JOIN Sales.SalesOrderDetail AS d
                  ON ct.SalesOrderID = d.SalesOrderID
                 AND ct.SalesOrderDetailID = d.SalesOrderDetailID
            """
            cur_src.execute(sql_ct_detail, (last_v_detail,))
            detail_rows = cur_src.fetchall()
            lignes_lues += len(detail_rows)

            for row in detail_rows:
                op, order_id, detail_id, qty, p_id, unit_price, discount = row

                if op == "D":
                    cur_dst.execute(
                        "DELETE FROM dm.FaitVente WHERE NumCommande = ? AND NumLigne = ?",
                        (order_id, detail_id),
                    )
                    lignes_supprimees += cur_dst.rowcount

                elif op == "I" and qty is not None:
                    montant = round(float(qty) * float(unit_price) * (1.0 - float(discount)), 2)
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

                elif op == "U" and qty is not None:
                    montant = round(float(qty) * float(unit_price) * (1.0 - float(discount)), 2)
                    cur_dst.execute(
                        """
                        UPDATE dm.FaitVente
                        SET Quantite = ?, PrixUnitaire = ?, Montant = ?
                        WHERE NumCommande = ? AND NumLigne = ?
                        """,
                        (qty, unit_price, montant, order_id, detail_id),
                    )
                    lignes_maj += cur_dst.rowcount

        if current_version is not None:
            cur_dst.execute(
                "UPDATE meta.EtatCT SET DerniereVersion = ?, DateMaj = ? WHERE TableSource IN ('Product', 'SalesOrderHeader', 'SalesOrderDetail')",
                (current_version, datetime.now()),
            )

        fin = datetime.now()
        duree = time.perf_counter() - t0
        msg = f"Chargement incrémental CT terminé en {duree:.2f}s"
        cur_dst.execute(
            """
            INSERT INTO meta.JournalChargement (Methode, Debut, Fin, LignesLues, LignesInserees,
                                                LignesMisesAJour, LignesSupprimees, LignesRejetees, Statut, Message)
            VALUES (?, ?, ?, ?, ?, ?, ?, 0, 'SUCCES', ?)
            """,
            ("CT", debut, fin, lignes_lues, lignes_inserees, lignes_maj, lignes_supprimees, msg),
        )

        conn_dst.commit()
        print(msg)

    except Exception as exc:
        conn_dst.rollback()
        cur_dst.execute(
            """
            INSERT INTO meta.JournalChargement (Methode, Debut, Fin, LignesLues, LignesInserees,
                                                LignesMisesAJour, LignesSupprimees, LignesRejetees, Statut, Message)
            VALUES ('CT', ?, ?, 0, 0, 0, 0, 0, 'ERREUR', ?)
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