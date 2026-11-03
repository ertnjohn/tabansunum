USE DM_Ventes_CT;
GO

SET NOCOUNT ON;
SET XACT_ABORT ON;

DECLARE @Debut DATETIME2(3) = SYSDATETIME();
DECLARE @LignesLues INT = 0;
DECLARE @LignesProd INT = 0;
DECLARE @LignesFait INT = 0;
DECLARE @LignesInserees INT = 0;
DECLARE @DureeMs INT = 0;
DECLARE @Message NVARCHAR(4000);

BEGIN TRY
    BEGIN TRANSACTION;

    IF NOT EXISTS (SELECT 1 FROM dm.DimDate)
    BEGIN
        INSERT INTO dm.DimDate (CleDate, [Date], Annee, Trimestre, Mois, NomMois, Jour, JourSemaine)
        SELECT CleDate, [Date], Annee, Trimestre, Mois, NomMois, Jour, JourSemaine
        FROM DM_Ventes_CDC.dm.DimDate;
    END;

    DELETE FROM dm.FaitVente;
    DELETE FROM dm.DimProduit;

    IF EXISTS (
        SELECT 1 FROM sys.identity_columns
        WHERE object_id = OBJECT_ID(N'dm.DimProduit') AND last_value IS NOT NULL
    )
        DBCC CHECKIDENT (N'dm.DimProduit', RESEED, 0);

    SELECT @LignesLues =
          (SELECT COUNT(*) FROM stg.Product)
        + (SELECT COUNT(*) FROM stg.ProductSubcategory)
        + (SELECT COUNT(*) FROM stg.ProductCategory)
        + (SELECT COUNT(*) FROM stg.SalesOrderHeader)
        + (SELECT COUNT(*) FROM stg.SalesOrderDetail);

    INSERT INTO dm.DimProduit (
        ProductID, CodeProduit, Nom, SousCategorie, Categorie,
        PrixCatalogue, DateDebut, DateFin, EstCourant
    )
    SELECT
        p.ProductID,
        p.ProductNumber,
        p.Name,
        ISNULL(sc.Name, N'Inconnu'),
        ISNULL(c.Name, N'Inconnu'),
        p.ListPrice,
        CAST('2010-01-01 00:00:00.000' AS DATETIME2(3)),
        CAST(NULL AS DATETIME2(3)),
        CAST(1 AS BIT)
    FROM stg.Product AS p
    LEFT JOIN stg.ProductSubcategory AS sc
        ON sc.ProductSubcategoryID = p.ProductSubcategoryID
    LEFT JOIN stg.ProductCategory AS c
        ON c.ProductCategoryID = sc.ProductCategoryID
    ORDER BY p.ProductID ASC
    OPTION (MAXDOP 1);

    SET @LignesProd = @@ROWCOUNT;

    INSERT INTO dm.FaitVente (
        NumCommande, NumLigne, CleDate, CleProduit,
        Quantite, PrixUnitaire, Montant
    )
    SELECT
        d.SalesOrderID,
        d.SalesOrderDetailID,
        YEAR(h.OrderDate) * 10000 + MONTH(h.OrderDate) * 100 + DAY(h.OrderDate),
        dp.CleProduit,
        d.OrderQty,
        d.UnitPrice,
        CAST(d.OrderQty * d.UnitPrice AS MONEY)
    FROM stg.SalesOrderDetail AS d
    INNER JOIN stg.SalesOrderHeader AS h
        ON h.SalesOrderID = d.SalesOrderID
    INNER JOIN dm.DimProduit AS dp
        ON dp.ProductID = d.ProductID
       AND dp.DateDebut <= h.OrderDate
       AND (dp.DateFin IS NULL OR dp.DateFin > h.OrderDate)
    ORDER BY d.SalesOrderID ASC, d.SalesOrderDetailID ASC;

    SET @LignesFait = @@ROWCOUNT;
    SET @LignesInserees = @LignesProd + @LignesFait;
    SET @DureeMs = DATEDIFF(MILLISECOND, @Debut, SYSDATETIME());
    SET @Message = CONCAT(
        N'Transformation ELT reussie en ', @DureeMs,
        N' ms (DimProduit=', @LignesProd,
        N', FaitVente=', @LignesFait, N')'
    );

    INSERT INTO meta.JournalChargement (
        Methode, Debut, Fin, LignesLues, LignesInserees,
        LignesMisesAJour, LignesSupprimees, LignesRejetees, Statut, Message
    )
    VALUES (
        'ELT', @Debut, SYSDATETIME(), @LignesLues, @LignesInserees,
        0, 0, 0, N'SUCCES', @Message
    );

    COMMIT TRANSACTION;
END TRY
BEGIN CATCH
    IF @@TRANCOUNT > 0
        ROLLBACK TRANSACTION;

    DECLARE @ErrMsg NVARCHAR(4000) = ERROR_MESSAGE();

    INSERT INTO meta.JournalChargement (
        Methode, Debut, Fin, LignesLues, LignesInserees,
        LignesMisesAJour, LignesSupprimees, LignesRejetees, Statut, Message
    )
    VALUES (
        'ELT', @Debut, SYSDATETIME(), 0, 0,
        0, 0, 0, N'ERREUR', @ErrMsg
    );

    THROW;
END CATCH;
GO
