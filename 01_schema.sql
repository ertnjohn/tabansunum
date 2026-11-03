/* =====================================================================
   01_schema.sql  -  Bases, schemas dm / meta / stg, tables et contraintes

   Cree les deux data marts VIDES :
     - DM_Ventes_CDC : schemas dm et meta          (ETL + CDC)
     - DM_Ventes_CT  : schemas dm, meta et stg     (ELT + Change Tracking)

   ATTENTION : ce script SUPPRIME et recree les deux bases.
   A executer UNE SEULE FOIS, au tout debut, avant tout chargement.

   Choix de conception (justifies dans le rapport) :
     1. Version courante : DateFin = NULL
     2. DateDebut / DateFin : DATETIME2(3) (precision a la milliseconde)
     3. Premiere version de chaque produit : DateDebut = '2010-01-01'
     4. CleDate = AAAAMMJJ (INT) = annee*10000 + mois*100 + jour
     5. Prix et montants : MONEY (meme type que la source)
     6. Cle de FaitVente : (NumCommande, NumLigne) = cle de SalesOrderDetail
     7. Noms de colonnes en francais, sans accents
   ===================================================================== */

USE master;
GO

/* ---------- 1. Remise a zero ---------- */
IF DB_ID(N'DM_Ventes_CDC') IS NOT NULL
BEGIN
    ALTER DATABASE DM_Ventes_CDC SET SINGLE_USER WITH ROLLBACK IMMEDIATE;
    DROP DATABASE DM_Ventes_CDC;
END;
GO

IF DB_ID(N'DM_Ventes_CT') IS NOT NULL
BEGIN
    ALTER DATABASE DM_Ventes_CT SET SINGLE_USER WITH ROLLBACK IMMEDIATE;
    DROP DATABASE DM_Ventes_CT;
END;
GO

/* ---------- 2. Bases ---------- */
CREATE DATABASE DM_Ventes_CDC;
GO
CREATE DATABASE DM_Ventes_CT;
GO


/* =====================================================================
   DM_Ventes_CDC
   ===================================================================== */
USE DM_Ventes_CDC;
GO

/* ---------- 3. Schemas ---------- */
CREATE SCHEMA dm;
GO
CREATE SCHEMA meta;
GO

/* ---------- 4. Tables dm ---------- */
CREATE TABLE dm.DimDate (
    CleDate      INT          NOT NULL CONSTRAINT PK_DimDate PRIMARY KEY,
    [Date]       DATE         NOT NULL CONSTRAINT UQ_DimDate_Date UNIQUE,
    Annee        SMALLINT     NOT NULL,
    Trimestre    TINYINT      NOT NULL,
    Mois         TINYINT      NOT NULL,
    NomMois      NVARCHAR(20) NOT NULL,
    Jour         TINYINT      NOT NULL,
    JourSemaine  NVARCHAR(20) NOT NULL
);

CREATE TABLE dm.DimProduit (
    CleProduit     INT IDENTITY(1,1) NOT NULL CONSTRAINT PK_DimProduit PRIMARY KEY,
    ProductID      INT           NOT NULL,          -- cle metier (source)
    CodeProduit    NVARCHAR(25)  NOT NULL,
    Nom            NVARCHAR(50)  NOT NULL,          -- SCD 1
    SousCategorie  NVARCHAR(50)  NOT NULL,          -- SCD 2, 'Inconnu' si absente
    Categorie      NVARCHAR(50)  NOT NULL,          -- 'Inconnu' si absente
    PrixCatalogue  MONEY         NOT NULL,          -- SCD 2
    DateDebut      DATETIME2(3)  NOT NULL,
    DateFin        DATETIME2(3)  NULL,              -- NULL = version courante
    EstCourant     BIT           NOT NULL,
    CONSTRAINT CK_DimProduit_Periode  CHECK (DateFin IS NULL OR DateFin > DateDebut),
    CONSTRAINT CK_DimProduit_Courant  CHECK ((EstCourant = 1 AND DateFin IS NULL)
                                          OR (EstCourant = 0 AND DateFin IS NOT NULL))
);

/* Une seule version courante par produit */
CREATE UNIQUE INDEX UX_DimProduit_Courant ON dm.DimProduit (ProductID) WHERE EstCourant = 1;
/* Recherche de la version valide a une date */
CREATE INDEX IX_DimProduit_Periode ON dm.DimProduit (ProductID, DateDebut, DateFin);

CREATE TABLE dm.FaitVente (
    NumCommande   INT      NOT NULL,                -- SalesOrderDetail.SalesOrderID
    NumLigne      INT      NOT NULL,                -- SalesOrderDetail.SalesOrderDetailID
    CleDate       INT      NOT NULL CONSTRAINT FK_FaitVente_DimDate    REFERENCES dm.DimDate (CleDate),
    CleProduit    INT      NOT NULL CONSTRAINT FK_FaitVente_DimProduit REFERENCES dm.DimProduit (CleProduit),
    Quantite      SMALLINT NOT NULL,
    PrixUnitaire  MONEY    NOT NULL,
    Montant       MONEY    NOT NULL,                -- Quantite * PrixUnitaire
    CONSTRAINT PK_FaitVente PRIMARY KEY (NumCommande, NumLigne)
);

/* ---------- 5. Tables meta ---------- */
CREATE TABLE meta.DictionnaireDonnees (
    TableCible    NVARCHAR(128) NOT NULL,
    ColonneCible  NVARCHAR(128) NOT NULL,
    Definition    NVARCHAR(500) NOT NULL,
    CONSTRAINT PK_DictionnaireDonnees PRIMARY KEY (TableCible, ColonneCible)
);

CREATE TABLE meta.MappingColonnes (
    IdMapping            INT IDENTITY(1,1) NOT NULL CONSTRAINT PK_MappingColonnes PRIMARY KEY,
    TableCible           NVARCHAR(128)  NOT NULL,
    ColonneCible         NVARCHAR(128)  NOT NULL,
    TablesSources        NVARCHAR(400)  NULL,       -- NULL si generee (ex. DimDate)
    ColonnesSources      NVARCHAR(400)  NULL,
    RegleTransformation  NVARCHAR(1000) NOT NULL
);

CREATE TABLE meta.JournalChargement (
    IdExecution       INT IDENTITY(1,1) NOT NULL CONSTRAINT PK_JournalChargement PRIMARY KEY,
    Methode           VARCHAR(10)    NOT NULL CONSTRAINT CK_Journal_Methode CHECK (Methode IN ('ETL', 'ELT', 'CDC', 'CT')),
    Debut             DATETIME2(3)   NOT NULL,
    Fin               DATETIME2(3)   NULL,
    LignesLues        INT            NOT NULL DEFAULT 0,
    LignesInserees    INT            NOT NULL DEFAULT 0,
    LignesMisesAJour  INT            NOT NULL DEFAULT 0,
    LignesSupprimees  INT            NOT NULL DEFAULT 0,
    LignesRejetees    INT            NOT NULL DEFAULT 0,
    Statut            NVARCHAR(20)   NOT NULL,
    Message           NVARCHAR(4000) NULL
);

CREATE TABLE meta.EtatCDC (
    TableSource  NVARCHAR(128) NOT NULL CONSTRAINT PK_EtatCDC PRIMARY KEY,   -- ex. N'Production.Product'
    DernierLSN   BINARY(10)    NOT NULL,
    DateMaj      DATETIME2(3)  NOT NULL DEFAULT SYSDATETIME()
);
GO


/* =====================================================================
   DM_Ventes_CT
   ===================================================================== */
USE DM_Ventes_CT;
GO

/* ---------- 3. Schemas ---------- */
CREATE SCHEMA dm;
GO
CREATE SCHEMA meta;
GO
CREATE SCHEMA stg;
GO

/* ---------- 4. Tables dm (identiques a DM_Ventes_CDC) ---------- */
CREATE TABLE dm.DimDate (
    CleDate      INT          NOT NULL CONSTRAINT PK_DimDate PRIMARY KEY,
    [Date]       DATE         NOT NULL CONSTRAINT UQ_DimDate_Date UNIQUE,
    Annee        SMALLINT     NOT NULL,
    Trimestre    TINYINT      NOT NULL,
    Mois         TINYINT      NOT NULL,
    NomMois      NVARCHAR(20) NOT NULL,
    Jour         TINYINT      NOT NULL,
    JourSemaine  NVARCHAR(20) NOT NULL
);

CREATE TABLE dm.DimProduit (
    CleProduit     INT IDENTITY(1,1) NOT NULL CONSTRAINT PK_DimProduit PRIMARY KEY,
    ProductID      INT           NOT NULL,
    CodeProduit    NVARCHAR(25)  NOT NULL,
    Nom            NVARCHAR(50)  NOT NULL,
    SousCategorie  NVARCHAR(50)  NOT NULL,
    Categorie      NVARCHAR(50)  NOT NULL,
    PrixCatalogue  MONEY         NOT NULL,
    DateDebut      DATETIME2(3)  NOT NULL,
    DateFin        DATETIME2(3)  NULL,
    EstCourant     BIT           NOT NULL,
    CONSTRAINT CK_DimProduit_Periode  CHECK (DateFin IS NULL OR DateFin > DateDebut),
    CONSTRAINT CK_DimProduit_Courant  CHECK ((EstCourant = 1 AND DateFin IS NULL)
                                          OR (EstCourant = 0 AND DateFin IS NOT NULL))
);

CREATE UNIQUE INDEX UX_DimProduit_Courant ON dm.DimProduit (ProductID) WHERE EstCourant = 1;
CREATE INDEX IX_DimProduit_Periode ON dm.DimProduit (ProductID, DateDebut, DateFin);

CREATE TABLE dm.FaitVente (
    NumCommande   INT      NOT NULL,
    NumLigne      INT      NOT NULL,
    CleDate       INT      NOT NULL CONSTRAINT FK_FaitVente_DimDate    REFERENCES dm.DimDate (CleDate),
    CleProduit    INT      NOT NULL CONSTRAINT FK_FaitVente_DimProduit REFERENCES dm.DimProduit (CleProduit),
    Quantite      SMALLINT NOT NULL,
    PrixUnitaire  MONEY    NOT NULL,
    Montant       MONEY    NOT NULL,
    CONSTRAINT PK_FaitVente PRIMARY KEY (NumCommande, NumLigne)
);

/* ---------- 5. Tables meta ---------- */
CREATE TABLE meta.DictionnaireDonnees (
    TableCible    NVARCHAR(128) NOT NULL,
    ColonneCible  NVARCHAR(128) NOT NULL,
    Definition    NVARCHAR(500) NOT NULL,
    CONSTRAINT PK_DictionnaireDonnees PRIMARY KEY (TableCible, ColonneCible)
);

CREATE TABLE meta.MappingColonnes (
    IdMapping            INT IDENTITY(1,1) NOT NULL CONSTRAINT PK_MappingColonnes PRIMARY KEY,
    TableCible           NVARCHAR(128)  NOT NULL,
    ColonneCible         NVARCHAR(128)  NOT NULL,
    TablesSources        NVARCHAR(400)  NULL,
    ColonnesSources      NVARCHAR(400)  NULL,
    RegleTransformation  NVARCHAR(1000) NOT NULL
);

CREATE TABLE meta.JournalChargement (
    IdExecution       INT IDENTITY(1,1) NOT NULL CONSTRAINT PK_JournalChargement PRIMARY KEY,
    Methode           VARCHAR(10)    NOT NULL CONSTRAINT CK_Journal_Methode CHECK (Methode IN ('ETL', 'ELT', 'CDC', 'CT')),
    Debut             DATETIME2(3)   NOT NULL,
    Fin               DATETIME2(3)   NULL,
    LignesLues        INT            NOT NULL DEFAULT 0,
    LignesInserees    INT            NOT NULL DEFAULT 0,
    LignesMisesAJour  INT            NOT NULL DEFAULT 0,
    LignesSupprimees  INT            NOT NULL DEFAULT 0,
    LignesRejetees    INT            NOT NULL DEFAULT 0,
    Statut            NVARCHAR(20)   NOT NULL,
    Message           NVARCHAR(4000) NULL
);

CREATE TABLE meta.EtatCT (
    TableSource      NVARCHAR(128) NOT NULL CONSTRAINT PK_EtatCT PRIMARY KEY,   -- ex. N'Production.Product'
    DerniereVersion  BIGINT        NOT NULL,
    DateMaj          DATETIME2(3)  NOT NULL DEFAULT SYSDATETIME()
);

/* ---------- 6. Tables stg : copie brute des sources (ELT) ----------
   Memes noms et memes types que dans AdventureWorks, aucune transformation. */
CREATE TABLE stg.Product (
    ProductID             INT          NOT NULL CONSTRAINT PK_stg_Product PRIMARY KEY,
    Name                  NVARCHAR(50) NOT NULL,
    ProductNumber         NVARCHAR(25) NOT NULL,
    ListPrice             MONEY        NOT NULL,
    ProductSubcategoryID  INT          NULL,
    ModifiedDate          DATETIME     NOT NULL
);

CREATE TABLE stg.ProductSubcategory (
    ProductSubcategoryID  INT          NOT NULL CONSTRAINT PK_stg_ProductSubcategory PRIMARY KEY,
    ProductCategoryID     INT          NOT NULL,
    Name                  NVARCHAR(50) NOT NULL
);

CREATE TABLE stg.ProductCategory (
    ProductCategoryID  INT          NOT NULL CONSTRAINT PK_stg_ProductCategory PRIMARY KEY,
    Name               NVARCHAR(50) NOT NULL
);

CREATE TABLE stg.SalesOrderHeader (
    SalesOrderID  INT      NOT NULL CONSTRAINT PK_stg_SalesOrderHeader PRIMARY KEY,
    OrderDate     DATETIME NOT NULL
);

CREATE TABLE stg.SalesOrderDetail (
    SalesOrderID        INT      NOT NULL,
    SalesOrderDetailID  INT      NOT NULL,
    ProductID           INT      NOT NULL,
    OrderQty            SMALLINT NOT NULL,
    UnitPrice           MONEY    NOT NULL,
    UnitPriceDiscount   MONEY    NOT NULL,
    CONSTRAINT PK_stg_SalesOrderDetail PRIMARY KEY (SalesOrderID, SalesOrderDetailID)
);
GO


/* =====================================================================
   7. Verification : liste des tables creees
   ===================================================================== */
SELECT 'DM_Ventes_CDC' AS Base, s.name AS SchemaCible, t.name AS TableCible
FROM   DM_Ventes_CDC.sys.tables  AS t
JOIN   DM_Ventes_CDC.sys.schemas AS s ON s.schema_id = t.schema_id
UNION ALL
SELECT 'DM_Ventes_CT', s.name, t.name
FROM   DM_Ventes_CT.sys.tables  AS t
JOIN   DM_Ventes_CT.sys.schemas AS s ON s.schema_id = t.schema_id
ORDER BY Base, SchemaCible, TableCible;
