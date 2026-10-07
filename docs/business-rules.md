# Règles métier — JËND PRO

> Source de vérité des règles métier V1. Toute règle implémentée en SQL/Edge Function
> doit être décrite ici ; c'est aussi la spécification de référence pour la future
> couche Laravel (V2).

## 1. Argent et devise

### 1.1 Représentation
- Devise V1 : **XOF (franc CFA BCEAO)**. ISO 4217 : **0 décimale** — il n'existe pas de
  centimes en circulation.
- Tous les montants sont stockés en **`bigint` d'unités entières de la devise**
  (pour XOF : francs). `1 500 FCFA` → `1500`.
- **Interdits** : `float`, `double precision`, `real`, `money` (type PostgreSQL dépendant de la locale).
- Chaque entreprise a un `currency_code` (défaut `XOF`). Tous les montants d'une
  entreprise sont dans sa devise ; pas de conversion en V1. Une future devise à
  décimales (ex. GHS) serait stockée en unités mineures, le nombre de décimales étant
  dérivé du code ISO.
- Côté client : afficher via un formateur (`1 500 FCFA`), ne jamais faire de calcul
  financier de référence côté client.

### 1.2 Arrondis
- Quantités en `numeric(14,3)` (vente au kg / litre possible).
- `line_total = round(quantity × unit_price) − line_discount`, arrondi **au franc le plus
  proche, demi vers le haut** (`round()` PostgreSQL sur `numeric`).
- Les totaux sont toujours la **somme des lignes déjà arrondies** (jamais un arrondi d'une somme non arrondie).
- Tous les calculs sont faits **côté serveur** dans les RPC ; les totaux envoyés par le
  client sont ignorés.

### 1.3 Signes
- Prix, coûts, montants de paiement, dépenses : `≥ 0` (contrainte `CHECK`).
- Grands livres (stock, compte client) : valeurs **signées** avec contrainte de signe par type.

## 2. Produits

- `sale_price` et `cost_price` ≥ 0. Un prix de vente inférieur au coût est **autorisé**
  (promotion) mais pourra déclencher un avertissement.
- Le coût d'achat est stocké à part (`product_costs`) et n'est visible qu'avec `products.read_cost`.
- `sku` et `barcode` uniques par entreprise lorsqu'ils sont renseignés (vide = non renseigné).
- `track_stock = false` pour les services / articles non stockés : aucune ligne
  d'inventaire, aucun contrôle de stock. Choisi à la création, **non modifiable** ensuite
  (changer ce mode avec du stock existant fausserait l'inventaire).
- `allows_fractional_quantity = false` (défaut) : seules des quantités entières sont
  acceptées en vente, achat et mouvement (téléphone, bouteille) ; `true` pour la vente au
  kg / litre / mètre.
- Catégories sur deux niveaux maximum.
- Un produit référencé par de l'historique n'est **jamais supprimé** : il est archivé
  (`ARCHIVED`), n'apparaît plus à la vente, mais reste lisible dans l'historique.
- Les lignes de vente/achat **figent** nom, prix et coût au moment de l'opération :
  modifier un produit ne réécrit jamais l'historique.

## 3. Stock

### 3.1 Principe
- Le stock courant (`inventory.quantity`) est un **cache** de la somme des mouvements
  (`inventory_movements`) par produit et emplacement.
- **Aucune** modification de stock sans mouvement associé, dans la même transaction
  (fonction unique `private.apply_stock_movement`).
- Invariant vérifiable à tout moment (test + requête d'audit) :
  `inventory.quantity = SUM(inventory_movements.quantity)`.

### 3.2 Types de mouvements

| Type | Signe | Origine | Permission |
|---|---|---|---|
| `INITIAL` | + | Stock d'ouverture — **une seule fois** par produit × emplacement | `inventory.adjust` |
| `PURCHASE` | + | Réception d'un achat | `purchases.receive` |
| `SALE` | − | Vente | `sales.create` |
| `SALE_CANCELLATION` | + | Annulation d'une vente | `sales.cancel` |
| `RETURN` | + | Retour client (partiel) | `sales.cancel` |
| `ADJUSTMENT` | ± | Correction manuelle ou inventaire physique (`count_stock`) — motif obligatoire | `inventory.adjust` |
| `TRANSFER_OUT` / `TRANSFER_IN` | − / + | Transfert entre emplacements (paire liée par `transfer_id`) | `inventory.transfer` |
| `LOSS` | − | Perte, vol | `inventory.adjust` |
| `DAMAGE` | − | Casse, péremption | `inventory.adjust` |

Opérations disponibles (Phase 6) :
- `adjust_stock(business, product, location, type, quantity, reason)` : `quantity` est le
  **delta signé** (`LOSS -3` = perte de 3). Types acceptés : `INITIAL`, `ADJUSTMENT`, `LOSS`, `DAMAGE`.
- `count_stock(business, product, location, counted, reason?)` : inventaire physique ; le
  serveur calcule l'écart **sous verrou** (une vente simultanée n'est jamais perdue).
- `transfer_stock(business, product, from, to, quantity, reason?)` : paire
  `TRANSFER_OUT` / `TRANSFER_IN`, tout ou rien.
- Les mouvements `PURCHASE`, `SALE`, `SALE_CANCELLATION`, `RETURN` ne sont **jamais** saisis
  manuellement : ils sont produits par les achats et les ventes.
- Produits `allows_fractional_quantity = false` : quantités entières uniquement ; produits
  `track_stock = false` : aucun mouvement possible.
- Aucun mouvement sur un emplacement archivé ; on n'archive pas un emplacement qui a du stock.

### 3.3 Stock négatif
- **Interdit par défaut.** Une vente ou sortie qui rendrait le stock négatif échoue
  entièrement (aucune écriture partielle).
- Une entreprise peut l'autoriser explicitement (`businesses.allow_negative_stock = true`),
  par exemple pour vendre avant d'avoir saisi un achat. Le changement de ce paramètre est audité.

### 3.4 Concurrence
- Chaque mouvement verrouille la ligne `inventory` concernée (`SELECT … FOR UPDATE`).
- Les lignes d'une même opération sont traitées dans un **ordre déterministe**
  (par `product_id`) pour éviter les interblocages entre ventes simultanées.

### 3.5 Valorisation
- V1 : **coût moyen pondéré** (CMP) recalculé à chaque réception d'achat :
  `nouveau_coût = round((stock × coût_actuel + qté_reçue × coût_achat) / (stock + qté_reçue))`.
- Le `unit_cost` figé sur chaque ligne de vente permet le calcul de la marge estimée.

### 3.6 Stock faible
- Alerte lorsque `quantity ≤ min_stock_level` après un mouvement sortant → notification
  `LOW_STOCK` (dédupliquée : une alerte tant que le stock n'est pas remonté au-dessus du seuil).

## 4. Ventes

### 4.1 Création (`create_sale`) — une seule transaction ✅
1. Vérifier `sales.create` (+ `sales.discount` si remise, + `sales.credit` si crédit).
2. Idempotence : si `client_reference` existe déjà pour l'entreprise → renvoyer la vente
   existante, **même si le contenu envoyé diffère** (un rejeu n'est jamais une nouvelle vente).
3. Lire produits **de l'entreprise** : le prix est **toujours** le prix catalogue (le client
   ne peut pas imposer un prix) ; une réduction passe par une remise explicite. Refuser
   produits archivés, quantités fractionnaires interdites, doublons de produit.
4. Calculer lignes, sous-total, remise, total.
5. Numéroter la vente (`document_sequences`, sous verrou).
6. Insérer `sales` + `sale_items`.
7. Mouvements de stock `SALE` (ordre déterministe, contrôle stock négatif).
8. Enregistrer les paiements (`payments`, direction `IN`), éventuellement multiples
   (ex. 5 000 cash + 10 000 Wave).
9. Si reste dû > 0 : vérifier client obligatoire + plafond de crédit, écrire
   `customer_transactions (CREDIT_SALE)` et mettre à jour `customers.balance`.
10. Audit des remises (`sale.discount`) ; notifications (vente importante, stock faible) en Phase 12.

Toute erreur à n'importe quelle étape annule **tout**.

### 4.2 Paiement d'une vente
- `amount_paid + credit_amount = total_amount`.
- Rendu monnaie : l'app n'envoie que le montant dû ; la monnaie rendue est un calcul
  d'affichage, pas un paiement. Paiements > total → `PAYMENT_EXCEEDS_TOTAL`.
- `payment_status` (dérivé) : `PAID` si tout est payé à la caisse, `PARTIAL` si une partie
  est à crédit, `UNPAID` si tout est à crédit. Les règlements ultérieurs du crédit sont suivis
  sur le **compte client**, pas sur la vente.
- Vente à crédit impossible sans client identifié.

### 4.3 Annulation (`cancel_sale`)
- Permission `sales.cancel`, motif obligatoire, vente `COMPLETED` uniquement.
- Annulation **totale** uniquement en V1 (pas de retour partiel).
- Remise en stock (`SALE_CANCELLATION`) à l'emplacement de la vente.
- Crédit : la part à crédit est annulée **dans la limite du solde actuel du client**
  (`SALE_CANCELLATION`) ; la partie de ce crédit que le client a déjà réglée lui est
  remboursée. Remboursement total = payé à la caisse + crédit déjà réglé, enregistré comme
  un paiement `OUT` lié à la vente (moyen choisi, défaut `CASH`). Les paiements `IN`
  d'origine ne sont jamais modifiés.
- Trésorerie = Σ paiements `IN` − Σ paiements `OUT`.
- Une vente n'est **jamais supprimée** ni modifiée après validation : on annule et on recrée.
- Délai d'annulation éventuellement limité (paramètre entreprise, à définir).

### 4.4 Remises
- Remise par ligne et/ou globale, en montant (FCFA), permission `sales.discount`.
  Une remise ne dépasse jamais le montant concerné. Toute vente avec remise est auditée.

## 5. Clients et crédit

- `customers.balance` = somme des `customer_transactions.amount` (cache, même principe que le stock).
- `credit_limit` : `0` (défaut) = pas de crédit, `NULL` = sans plafond, `> 0` = plafond.
  Une vente à crédit est refusée si `balance + crédit > credit_limit`.
- Règlement (`record_customer_payment`) : crée un `payment` (IN, `customer_id`, emplacement)
  et une transaction `PAYMENT` négative, atomiquement. Un règlement ne peut pas excéder le
  solde dû (pas d'avoir client en V1). Permission `customers.payments` (caissier inclus).
- Plafond de crédit modifiable uniquement via `set_customer_credit_limit` (`customers.manage`).
- Reprise de l'existant / correction : `adjust_customer_balance(client, montant signé, motif)`
  (`customers.manage`), ex. dettes du cahier de crédit au démarrage. Motif obligatoire.
- Un client qui doit de l'argent ne peut pas être archivé.
- Une vente à crédit exige un client actif.
- Toute écriture de crédit est auditée et traçable jusqu'à la vente d'origine.

## 6. Fournisseurs et achats

- Cycle : `DRAFT → ORDERED → RECEIVED`, ou `DRAFT/ORDERED → CANCELLED`
  (`ORDERED` est facultatif : on peut réceptionner directement un brouillon).
- `save_purchase` crée ou remplace **en bloc** les lignes d'un achat `DRAFT`/`ORDERED` ;
  totaux calculés par le serveur ; remise ≤ sous-total ; le nouveau total ne peut pas être
  inférieur aux acomptes déjà versés.
- La **réception** (`receive_purchase`) est atomique et unique : mouvements `PURCHASE`
  (lignes traitées par ordre de produit), mise à jour du CMP sur le stock total de
  l'entreprise (stock négatif compté comme 0), `supplier_products.last_cost`, statut
  `RECEIVED`, audit. Les lignes de produits non stockés n'ont pas d'effet sur le stock.
- Annulation : uniquement avant réception, sans paiement, motif obligatoire.
- Réception partielle : hors périmètre V1 (on crée un nouvel achat pour le reliquat).
- Un achat réceptionné n'est plus modifiable (correction par ajustement de stock audité).
- Dette fournisseur = `total_amount − amount_paid` des achats reçus ; paiements `OUT` liés
  à l'achat ; `amount_paid ≤ total_amount` ; acomptes autorisés avant réception ; pas de
  paiement sur un achat annulé. `payment_status` est dérivé automatiquement.

## 7. Dépenses

- Montant > 0, catégorie obligatoire, date de dépense (`spent_at`, pas forcément aujourd'hui).
- Justificatif optionnel (Storage `documents`, privé).
- Création, modification et suppression auditées (avec montant avant/après).

## 8. Employés

- Un **employé** (fiche RH : poste, salaire, embauche) est distinct d'un **membre**
  (compte qui se connecte). Un employé peut ne jamais se connecter ; un membre peut ne pas
  être salarié (ex. comptable externe). Lien optionnel `employees.member_id`.
- Salaire visible uniquement avec `employees.read`.

## 9. Abonnements

- Une entreprise a **au plus un abonnement non terminé** à la fois.
- À la création d'une entreprise : abonnement `TRIALING` (plan et durée à définir).
- Les limites du plan (`max_members`, `max_products`, `max_locations`) sont vérifiées par
  triggers à l'insertion ; dépasser une limite bloque la **création**, jamais la
  **lecture** ni la vente des éléments existants.
- Abonnement expiré : mode lecture seule, **mais ventes et règlements de crédit restent
  autorisés** (bloquer la caisse d'un commerçant est trop pénalisant).
- Les changements d'abonnement sont faits par Edge Function (`service_role`) après
  confirmation de paiement, et audités.

## 10. Numérotation des documents

- Numéros séquentiels **par entreprise et par type** : `V-000001` (vente), `A-000001` (achat).
- Générés en base sous verrou ; jamais par le client.
- Un numéro attribué n'est jamais réutilisé (une vente annulée garde son numéro).

## 11. Temps et rapports

- Horodatage en UTC (`timestamptz`) ; regroupements « par jour » selon `businesses.timezone`
  (défaut `Africa/Dakar`, UTC+0 sans heure d'été).
- Chiffre d'affaires = somme des `total_amount` des ventes `COMPLETED`.
- Marge estimée = Σ (`line_total − quantity × unit_cost`) des ventes `COMPLETED`.
- Panier moyen = CA / nombre de ventes `COMPLETED`.

## 12. Audit — opérations obligatoirement tracées

Changement de rôle / statut d'un membre · archivage produit · changement de prix ·
ajustement / perte / casse de stock · annulation de vente · remise au-delà d'un seuil ·
règlement de crédit · modification de plafond de crédit · réception / annulation
d'achat · création / modification / suppression de dépense · changement d'abonnement ·
modification des paramètres sensibles (`allow_negative_stock`, devise).

## 13. Contrat d'erreurs des RPC

Les RPC lèvent des erreurs dont le **message est un code machine stable** (le client le
traduit pour l'utilisateur) ; `detail` apporte un complément non contractuel.

| SQLSTATE | Message | Signification |
|---|---|---|
| `42501` | `NOT_AUTHENTICATED` | Aucune session |
| `42501` | `PERMISSION_DENIED` | Permission manquante ou entreprise inaccessible (même réponse : aucune fuite d'information) |
| `42501` | `ROLE_ABOVE_CALLER` | Rôle cible supérieur aux droits de l'appelant |
| `42501` | `CANNOT_MODIFY_SELF` | Action sur son propre rôle/statut |
| `P0001` | `LAST_OWNER` | L'entreprise perdrait son dernier OWNER actif |
| `P0001` | `ALREADY_MEMBER` | Utilisateur déjà membre ou invité |
| `P0001` | `BUSINESS_LIMIT_REACHED` | Limite d'entreprises possédées atteinte |
| `P0001` | `ROLE_NOT_IN_BUSINESS` | Rôle personnalisé d'une autre entreprise |
| `P0001` | `APPEND_ONLY` | Modification d'une table en ajout seul |
| `P0002` | `USER_NOT_FOUND`, `MEMBER_NOT_FOUND`, `ROLE_NOT_FOUND`, `INVITATION_NOT_FOUND` | Ressource introuvable |
| `22023` | `INVALID_TIMEZONE`, `INVALID_STATUS`, `INVALID_QUANTITY`, `INVALID_QUANTITY_SIGN`, `INVALID_MOVEMENT_TYPE`, `REASON_REQUIRED`, `SAME_LOCATION` | Paramètre invalide |
| `P0001` | `INSUFFICIENT_STOCK` (`detail` JSON : `product_id`, `location_id`, `available`, `requested`) | Stock insuffisant |
| `P0001` | `INITIAL_ALREADY_SET`, `PRODUCT_NOT_STOCKED`, `FRACTIONAL_QUANTITY_NOT_ALLOWED`, `LOCATION_ARCHIVED`, `LOCATION_HAS_STOCK`, `CATEGORY_TOO_DEEP` | Règle de stock / catalogue |
| `P0002` | `PRODUCT_NOT_FOUND`, `LOCATION_NOT_FOUND`, `CUSTOMER_NOT_FOUND` | Ressource absente de l'entreprise |
| `P0001` | `AMOUNT_EXCEEDS_BALANCE`, `CREDIT_LIMIT_EXCEEDED` (`detail` JSON), `CUSTOMER_HAS_BALANCE`, `CUSTOMER_ARCHIVED` | Règle de crédit client |
| `22023` | `INVALID_AMOUNT`, `ITEMS_REQUIRED`, `INVALID_ITEM`, `DUPLICATE_PRODUCT`, `DISCOUNT_EXCEEDS_TOTAL` | Montant / lignes invalides |
| `P0001` | `INVALID_PURCHASE_STATUS`, `PURCHASE_NOT_EDITABLE`, `PURCHASE_HAS_PAYMENTS`, `TOTAL_BELOW_AMOUNT_PAID` | Règle d'achat |
| `P0002` | `SUPPLIER_NOT_FOUND`, `PURCHASE_NOT_FOUND` | Ressource absente de l'entreprise |
| `22023` | `CLIENT_REFERENCE_REQUIRED`, `INVALID_PAYMENT`, `PAYMENT_EXCEEDS_TOTAL` | Vente invalide |
| `P0001` | `PRODUCT_ARCHIVED`, `CUSTOMER_REQUIRED_FOR_CREDIT`, `SALE_ALREADY_CANCELLED` | Règle de vente |
| `23514` / `23505` | (PostgreSQL) | Contrainte `CHECK` / unicité violée |

PostgREST renvoie `42501` en HTTP 401 (anonyme) ou 403 (connecté), les autres en 400/404/409.
