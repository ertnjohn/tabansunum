# Data mart des ventes – ETL / ELT et capture des changements (CDC / CT)

Projet : alimentation d'un data mart des ventes à partir d'AdventureWorks (OLTP),
par ETL + Change Data Capture d'une part, et par ELT + Change Tracking d'autre part.

## Membres et rôles

| Membre | Rôle |
|---|---|
| Erdem Ertan | Modélisation et métadonnées |
| _(à compléter)_ | ETL / ELT |
| _(à compléter)_ | Capture des changements et tests |

## Environnement

| Composant | Version |
|---|---|
| SQL Server | 2022 Developer Edition (16.0), SQL Server Agent en démarrage automatique |
| AdventureWorks / AdventureWorksDW | 2022 (même version pour les deux) |
| Python | _(à compléter)_ avec pandas et pyodbc |
| Pilote ODBC | ODBC Driver 18 for SQL Server (`TrustServerCertificate=yes` en local) |

## Ordre d'exécution

1. `01_schema.sql` – crée les deux bases vides (**supprime et recrée les bases**)
2. `02_metadonnees.sql` – métadonnées techniques, dictionnaire, lignage
3. `03_etl.py` – chargement initial par ETL vers `DM_Ventes_CDC` (+ `dm.DimDate`)
4. `04_elt.py` puis `04_elt.sql` – chargement initial par ELT vers `DM_Ventes_CT`
5. `05_activation_cdc_ct.sql` – activation de CDC et CT (script fourni), puis initialisation de `meta.EtatCDC` et `meta.EtatCT`
6. `06a_changements_partie1.sql` (script fourni)
7. `07_incremental_cdc.py` puis `08_incremental_ct.py`
8. `06b_changements_partie2.sql` (script fourni)
9. `07_incremental_cdc.py` puis `08_incremental_ct.py`
10. `09_tests.sql`

> Attention : `01_schema.sql` supprime `DM_Ventes_CDC` et `DM_Ventes_CT`. Ne l'exécuter qu'au début, avant tout chargement.
> Les scripts `05`, `06a` et `06b` sont fournis par l'enseignant et ne doivent pas être modifiés.

## Conventions de conception

| # | Choix |
|---|---|
| 1 | Version courante : `DateFin = NULL`, `EstCourant = 1` |
| 2 | `DateDebut` / `DateFin` : `DATETIME2(3)` |
| 3 | Première version de chaque produit (chargement initial) : `DateDebut = '2010-01-01'` |
| 4 | `CleDate` = AAAAMMJJ (INT) = année × 10000 + mois × 100 + jour |
| 5 | Prix et montants : `MONEY` (en Python : `Decimal`, jamais `float`) |
| 6 | Clé de `dm.FaitVente` : `(NumCommande, NumLigne)` = `(SalesOrderID, SalesOrderDetailID)` |
| 7 | Noms de colonnes en français, sans accents |

## Tables du data mart

**dm.DimDate** : `CleDate`, `Date`, `Annee`, `Trimestre`, `Mois`, `NomMois`, `Jour`, `JourSemaine`

**dm.DimProduit** : `CleProduit` (IDENTITY), `ProductID`, `CodeProduit`, `Nom`, `SousCategorie`, `Categorie`, `PrixCatalogue`, `DateDebut`, `DateFin`, `EstCourant`
- `Nom` : SCD 1 (écrase toutes les versions) ; `PrixCatalogue` et `SousCategorie` : SCD 2
- Sous-catégorie / catégorie absente : `'Inconnu'`

**dm.FaitVente** : `NumCommande`, `NumLigne`, `CleDate`, `CleProduit`, `Quantite`, `PrixUnitaire`, `Montant`
- `CleProduit` = version valide à la date de commande : `DateDebut <= OrderDate` et (`DateFin > OrderDate` ou `DateFin IS NULL`)
- `Montant` = `Quantite × PrixUnitaire`

**meta** : `JournalChargement`, `DictionnaireDonnees`, `MappingColonnes`, `EtatCDC` (DM_Ventes_CDC), `EtatCT` (DM_Ventes_CT)

**stg** (DM_Ventes_CT seulement) : copie brute de `Product`, `ProductSubcategory`, `ProductCategory`, `SalesOrderHeader`, `SalesOrderDetail`

## Structure du dépôt

```
README.md, requirements.txt
01_schema.sql … 09_tests.sql
captures/      C01 à C12
presentation/  présentation
rapport/       rapport (PDF)
```
