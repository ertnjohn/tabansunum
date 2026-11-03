import os
import time
from datetime import datetime
from decimal import Decimal, ROUND_HALF_UP
import pandas as pd
import pyodbc

SERVER = os.getenv("SQL_SERVER", "localhost")
SOURCE_DB = os.getenv("SOURCE_DB", "AdventureWorks")
TARGET_DB = "DM_Ventes_CDC"

MOIS_FR = {
    1: "Janvier", 2: "Fevrier", 3: "Mars", 4: "Avril",
    5: "Mai", 6: "Juin", 7: "Juillet", 8: "Aout",
    9: "Septembre", 10: "Octobre", 11: "Novembre", 12: "Decembre"
}

JOURS_FR = {
    0: "Lundi", 1: "Mardi", 2: "Mercredi", 3: "Jeudi",
    4: "Vendredi", 5: "Samedi", 6: "Dimanche"
}

def get_connection(database):
    conn_str = (
        f"DRIVER={{ODBC Driver 18 for SQL Server}};"
        f"SERVER={SERVER};"
        f"DATABASE={database};"
        f"Trusted_Connection=yes;"
        f"TrustServerCertificate=yes;"
    )
    return pyodbc.connect(conn_str, autocommit=False)

def to_money(val):
    return Decimal(str(val)).quantize(Decimal("0.0001"), rounding=ROUND_HALF_UP)

def generate_dim_date():
    dates = pd.date_range(start="2010-01-01", end="2030-12-31", freq="D")
    rows = []
    for d in dates:
        cle_date = d.year * 10000 + d.month * 100 + d.day
        trimestre = (d.month - 1) // 3 + 1
        rows.append((
            int(cle_date),
            d.date(),
            int(d.year),
            int(trimestre),
            int(d.month),
            MOIS_FR[d.month],
            int(d.day),
            JOURS_FR[d.weekday()]
        ))
    return rows

def batch_insert(cursor, sql, rows, batch_size=10000):
    cursor.fast_executemany = True
    for i in range(0, len(rows), batch_size):
        cursor.executemany(sql, rows[i:i + batch_size])

def main():
    t0 = time.perf_counter()
    debut = datetime.now()
    conn_src = get_connection(SOURCE_DB)
    conn_dst = get_connection(TARGET_DB)
    cur_src = conn_src.cursor()
    cur_dst = conn_dst.cursor()

    try:
        cur_dst.execute("DELETE FROM dm.FaitVente;")
        cur_dst.execute("DELETE FROM dm.DimProduit;")
        cur_dst.execute("IF EXISTS (SELECT 1 FROM sys.identity_columns WHERE object_id = OBJECT_ID(N'dm.DimProduit') AND last_value IS NOT NULL) DBCC CHECKIDENT (N'dm.DimProduit', RESEED, 0);")
        cur_dst.execute("DELETE FROM dm.DimDate;")
        conn_dst.commit()

        dim_date_rows = generate_dim_date()
        batch_insert(
            cur_dst,
            "INSERT INTO dm.DimDate (CleDate, [Date], Annee, Trimestre, Mois, NomMois, Jour, JourSemaine) VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
            dim_date_rows
        )
        conn_dst.commit()

        cur_src.execute("SELECT ProductID, Name, ProductNumber, ListPrice, ProductSubcategoryID FROM Production.Product")
        df_prod = pd.DataFrame.from_records(cur_src.fetchall(), columns=["ProductID", "Name", "ProductNumber", "ListPrice", "ProductSubcategoryID"])

        cur_src.execute("SELECT ProductSubcategoryID, ProductCategoryID, Name AS SousCategorie FROM Production.ProductSubcategory")
        df_subcat = pd.DataFrame.from_records(cur_src.fetchall(), columns=["ProductSubcategoryID", "ProductCategoryID", "SousCategorie"])

        cur_src.execute("SELECT ProductCategoryID, Name AS Categorie FROM Production.ProductCategory")
        df_cat = pd.DataFrame.from_records(cur_src.fetchall(), columns=["ProductCategoryID", "Categorie"])

        cur_src.execute("SELECT SalesOrderID, OrderDate FROM Sales.SalesOrderHeader")
        df_hdr = pd.DataFrame.from_records(cur_src.fetchall(), columns=["SalesOrderID", "OrderDate"])

        cur_src.execute("SELECT SalesOrderID, SalesOrderDetailID, ProductID, OrderQty, UnitPrice FROM Sales.SalesOrderDetail")
        df_dtl = pd.DataFrame.from_records(cur_src.fetchall(), columns=["SalesOrderID", "SalesOrderDetailID", "ProductID", "OrderQty", "UnitPrice"])

        lignes_lues = len(df_prod) + len(df_subcat) + len(df_cat) + len(df_hdr) + len(df_dtl)

        df_dim_prod = df_prod.merge(df_subcat, on="ProductSubcategoryID", how="left")
        df_dim_prod = df_dim_prod.merge(df_cat, on="ProductCategoryID", how="left")
        df_dim_prod["SousCategorie"] = df_dim_prod["SousCategorie"].fillna("Inconnu")
        df_dim_prod["Categorie"] = df_dim_prod["Categorie"].fillna("Inconnu")
        df_dim_prod = df_dim_prod.sort_values("ProductID").reset_index(drop=True)

        date_debut_init = datetime(2010, 1, 1, 0, 0, 0)
        dim_prod_rows = [
            (
                int(r.ProductID),
                str(r.ProductNumber),
                str(r.Name),
                str(r.SousCategorie),
                str(r.Categorie),
                to_money(r.ListPrice),
                date_debut_init,
                None,
                True
            )
            for r in df_dim_prod.itertuples(index=False)
        ]

        batch_insert(
            cur_dst,
            "INSERT INTO dm.DimProduit (ProductID, CodeProduit, Nom, SousCategorie, Categorie, PrixCatalogue, DateDebut, DateFin, EstCourant) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)",
            dim_prod_rows
        )
        conn_dst.commit()

        cur_dst.execute("SELECT CleProduit, ProductID, DateDebut, DateFin FROM dm.DimProduit")
        df_prod_lookup = pd.DataFrame.from_records(
            cur_dst.fetchall(),
            columns=["CleProduit", "ProductID", "DateDebut", "DateFin"]
        )

        df_ventes = df_dtl.merge(df_hdr, on="SalesOrderID", how="inner")
        df_ventes["OrderDate"] = pd.to_datetime(df_ventes["OrderDate"])
        df_ventes["CleDate"] = (
            df_ventes["OrderDate"].dt.year * 10000
            + df_ventes["OrderDate"].dt.month * 100
            + df_ventes["OrderDate"].dt.day
        )

        df_ventes = df_ventes.merge(df_prod_lookup, on="ProductID", how="inner")
        mask_valide = (df_ventes["OrderDate"] >= df_ventes["DateDebut"]) & (
            df_ventes["DateFin"].isna() | (df_ventes["OrderDate"] < df_ventes["DateFin"])
        )
        df_ventes = df_ventes[mask_valide].sort_values(["SalesOrderID", "SalesOrderDetailID"]).reset_index(drop=True)

        fait_rows = []
        for r in df_ventes.itertuples(index=False):
            qte = int(r.OrderQty)
            pu = to_money(r.UnitPrice)
            montant = to_money(Decimal(qte) * pu)
            fait_rows.append((
                int(r.SalesOrderID),
                int(r.SalesOrderDetailID),
                int(r.CleDate),
                int(r.CleProduit),
                qte,
                pu,
                montant
            ))

        batch_insert(
            cur_dst,
            "INSERT INTO dm.FaitVente (NumCommande, NumLigne, CleDate, CleProduit, Quantite, PrixUnitaire, Montant) VALUES (?, ?, ?, ?, ?, ?, ?)",
            fait_rows
        )

        fin = datetime.now()
        duree_sec = time.perf_counter() - t0
        lignes_inserees = len(dim_prod_rows) + len(fait_rows)
        msg = f"Chargement initial ETL reussi en {duree_sec:.2f}s (DimDate={len(dim_date_rows)}, DimProduit={len(dim_prod_rows)}, FaitVente={len(fait_rows)})"

        cur_dst.execute(
            "INSERT INTO meta.JournalChargement (Methode, Debut, Fin, LignesLues, LignesInserees, LignesMisesAJour, LignesSupprimees, LignesRejetees, Statut, Message) VALUES (?, ?, ?, ?, ?, 0, 0, 0, ?, ?)",
            ("ETL", debut, fin, int(lignes_lues), int(lignes_inserees), "SUCCES", msg)
        )
        conn_dst.commit()
        print(msg)

    except Exception as exc:
        conn_dst.rollback()
        fin = datetime.now()
        cur_dst.execute(
            "INSERT INTO meta.JournalChargement (Methode, Debut, Fin, LignesLues, LignesInserees, LignesMisesAJour, LignesSupprimees, LignesRejetees, Statut, Message) VALUES (?, ?, ?, 0, 0, 0, 0, 0, ?, ?)",
            ("ETL", debut, fin, "ERREUR", str(exc)[:4000])
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
