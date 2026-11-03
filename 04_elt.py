import os
import time
from decimal import Decimal, ROUND_HALF_UP
import pandas as pd
import pyodbc

SERVER = os.getenv("SQL_SERVER", "localhost")
SOURCE_DB = os.getenv("SOURCE_DB", "AdventureWorks2022")
TARGET_DB = "DM_Ventes_CT"

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
    conn_src = get_connection(SOURCE_DB)
    conn_dst = get_connection(TARGET_DB)
    cur_src = conn_src.cursor()
    cur_dst = conn_dst.cursor()

    try:
        cur_dst.execute("DELETE FROM dm.FaitVente;")
        cur_dst.execute("DELETE FROM dm.DimDate;")
        cur_dst.execute("TRUNCATE TABLE stg.SalesOrderDetail;")
        cur_dst.execute("TRUNCATE TABLE stg.SalesOrderHeader;")
        cur_dst.execute("TRUNCATE TABLE stg.Product;")
        cur_dst.execute("TRUNCATE TABLE stg.ProductSubcategory;")
        cur_dst.execute("TRUNCATE TABLE stg.ProductCategory;")
        conn_dst.commit()

        dim_date_rows = generate_dim_date()
        batch_insert(
            cur_dst,
            "INSERT INTO dm.DimDate (CleDate, [Date], Annee, Trimestre, Mois, NomMois, Jour, JourSemaine) VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
            dim_date_rows
        )
        conn_dst.commit()

        cur_src.execute("SELECT ProductID, Name, ProductNumber, ListPrice, ProductSubcategoryID, ModifiedDate FROM Production.Product")
        prod_rows = [
            (int(r[0]), str(r[1]), str(r[2]), to_money(r[3]), int(r[4]) if r[4] is not None else None, r[5])
            for r in cur_src.fetchall()
        ]
        batch_insert(
            cur_dst,
            "INSERT INTO stg.Product (ProductID, Name, ProductNumber, ListPrice, ProductSubcategoryID, ModifiedDate) VALUES (?, ?, ?, ?, ?, ?)",
            prod_rows
        )

        cur_src.execute("SELECT ProductSubcategoryID, ProductCategoryID, Name FROM Production.ProductSubcategory")
        subcat_rows = [(int(r[0]), int(r[1]), str(r[2])) for r in cur_src.fetchall()]
        batch_insert(
            cur_dst,
            "INSERT INTO stg.ProductSubcategory (ProductSubcategoryID, ProductCategoryID, Name) VALUES (?, ?, ?)",
            subcat_rows
        )

        cur_src.execute("SELECT ProductCategoryID, Name FROM Production.ProductCategory")
        cat_rows = [(int(r[0]), str(r[1])) for r in cur_src.fetchall()]
        batch_insert(
            cur_dst,
            "INSERT INTO stg.ProductCategory (ProductCategoryID, Name) VALUES (?, ?)",
            cat_rows
        )

        cur_src.execute("SELECT SalesOrderID, OrderDate FROM Sales.SalesOrderHeader")
        hdr_rows = [(int(r[0]), r[1]) for r in cur_src.fetchall()]
        batch_insert(
            cur_dst,
            "INSERT INTO stg.SalesOrderHeader (SalesOrderID, OrderDate) VALUES (?, ?)",
            hdr_rows
        )

        cur_src.execute("SELECT SalesOrderID, SalesOrderDetailID, ProductID, OrderQty, UnitPrice, UnitPriceDiscount FROM Sales.SalesOrderDetail")
        dtl_rows = [
            (int(r[0]), int(r[1]), int(r[2]), int(r[3]), to_money(r[4]), to_money(r[5]))
            for r in cur_src.fetchall()
        ]
        batch_insert(
            cur_dst,
            "INSERT INTO stg.SalesOrderDetail (SalesOrderID, SalesOrderDetailID, ProductID, OrderQty, UnitPrice, UnitPriceDiscount) VALUES (?, ?, ?, ?, ?, ?)",
            dtl_rows
        )

        conn_dst.commit()
        duree_sec = time.perf_counter() - t0
        total_stg = len(prod_rows) + len(subcat_rows) + len(cat_rows) + len(hdr_rows) + len(dtl_rows)
        print(f"Copie brute vers stg terminee en {duree_sec:.2f}s ({total_stg} lignes copiees, DimDate={len(dim_date_rows)}).")

    except Exception:
        conn_dst.rollback()
        raise
    finally:
        cur_src.close()
        cur_dst.close()
        conn_src.close()
        conn_dst.close()

if __name__ == "__main__":
    main()
