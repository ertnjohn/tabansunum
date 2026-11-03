-- =====================================================================
-- 09_tests.sql
-- Étape 6 : Tests de validation des données (Data Integrity Tests)
-- =====================================================================

-- TEST 2a : Chaque produit a exactement UNE SEULE version courante (EstCourant = 1)
-- Résultat attendu : 0 ligne (Aucun produit n'a 0 ou >1 version active)
SELECT ProductID, SUM(CAST(EstCourant AS INT)) AS NbVersionsActives
FROM dm.DimProduit
GROUP BY ProductID
HAVING SUM(CAST(EstCourant AS INT)) <> 1;

-- TEST 2b : Les versions d'un même produit ne se chevauchent pas dans le temps
-- Résultat attendu : 0 ligne (Aucune date de validité ne se croise)
SELECT p1.ProductID, p1.CleProduit AS Cle1, p2.CleProduit AS Cle2
FROM dm.DimProduit p1
JOIN dm.DimProduit p2 ON p1.ProductID = p2.ProductID AND p1.CleProduit <> p2.CleProduit
WHERE p1.DateDebut < ISNULL(p2.DateFin, '2099-12-31')
  AND ISNULL(p1.DateFin, '2099-12-31') > p2.DateDebut;

-- TEST 3 : Chaque ligne de fait est rattachée à la version de produit valide à la date de sa commande
-- Résultat attendu : 0 ligne (Aucune vente n'est liée à un produit expiré ou pas encore actif à cette date)
SELECT f.NumCommande, f.NumLigne, d.[Date] AS DateCommande, p.DateDebut, p.DateFin
FROM dm.FaitVente f
JOIN dm.DimProduit p ON f.CleProduit = p.CleProduit
JOIN dm.DimDate d ON f.CleDate = d.CleDate
WHERE d.[Date] < p.DateDebut OR d.[Date] >= ISNULL(p.DateFin, '2099-12-31');