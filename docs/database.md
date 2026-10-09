# Modèle de données — JËND PRO

> Statut : **modèle cible**, mis à jour à chaque phase pour refléter le schéma réel.
> ✅ = implémenté et testé · sans marque = cible, pas encore implémenté.
> Conventions de nommage, montants et suppression : voir [architecture.md §7](architecture.md#7-conventions).

## 1. Vue d'ensemble des domaines

```text
auth.users ──1:1── profiles
     │
     └──< business_members >── businesses ──< locations
                 │                  │
               roles ──< role_permissions >── permissions
                                    │
   ┌──────────────┬─────────────────┼──────────────────┬───────────────┐
categories     customers        suppliers          employees       expenses
   │               │                 │                                 │
products ─< supplier_products >──────┤                        expense_categories
   │               │                 │
inventory     customer_transactions purchases ─< purchase_items
(product×location)                   │
   │                                 │
inventory_movements ◄── sales ─< sale_items
                          │
                       payments  (vente, achat, règlement crédit client)

subscription_plans ─< subscriptions >── businesses
notifications (user × business)       audit_logs (business)
document_sequences (business × type)
```

`──<` = un-à-plusieurs. Toutes les tables tenant portent `business_id`.

## 2. Plan des migrations

| # | Migration | Phase | Contenu |
|---|---|---|---|
| ✅ 01 | `20261007150000_foundation` | 2 | Schéma `private`, révocation des privilèges par défaut, `set_updated_at()` |
| ✅ 02 | `20261007160000_profiles` | 3 | `profiles`, trigger de création à l'inscription |
| ✅ 03 | `20261007160100_tenancy_rbac` | 3-4 | `businesses`, `locations`, `business_members`, `permissions`, `roles`, `role_permissions`, seeds, helpers RLS, invariant dernier OWNER |
| ✅ 04 | `20261007160200_audit` | 4 | `audit_logs`, `private.log_audit()`, audit des paramètres entreprise |
| ✅ 05 | `20261007160300_tenancy_rpc` | 3-4 | RPC `create_business`, invitations, rôles, statuts, retrait, annuaire des membres |
| ✅ 06 | `20261007170000_catalog` | 5 | `categories`, `products`, `product_costs`, audit prix/coût, RPC `set_product_status` |
| ✅ 07 | `20261007170100_storage_catalog` | 5 | Buckets `product-images`, `business-assets` + policies par entreprise |
| ✅ 08 | `20261007180000_inventory` | 6 | `inventory`, `inventory_movements`, moteur `private.apply_stock_movement`, RPC `adjust_stock`, `count_stock`, `transfer_stock`, `list_low_stock` |
| ✅ 09 | `20261007190000_customers_payments` | 7 | `customers`, `customer_transactions`, `payments` (socle), moteur `private.apply_customer_transaction`, RPC `set_customer_credit_limit`, `record_customer_payment`, `adjust_customer_balance` |
| ✅ 10 | `20261007200000_suppliers_purchases` | 8 | `document_sequences`, `suppliers`, `supplier_products`, `purchases`, `purchase_items`, `payments.purchase_id`, vue `supplier_balances`, RPC `save_purchase`, `order_purchase`, `receive_purchase`, `cancel_purchase`, `record_purchase_payment` |
| ✅ 11 | `20261007210000_sales` | 9 | `sales`, `sale_items`, `sale_item_costs`, `payments.sale_id`, `customer_transactions.sale_id`, RPC `create_sale`, `cancel_sale` |
| ✅ 12 | `20261007220000_expenses_employees` | 10 | `expense_categories` (+ défauts), `expenses` (audit complet), `employees`, bucket privé `documents` |
| ✅ 13 | `20261007230000_subscriptions` | 11 | `subscription_plans` (+ 5 plans provisoires), `subscriptions`, essai 14 j, mode restreint (`permissions.allowed_when_restricted`), triggers de limites, RPC `get_subscription_status` |
| ✅ 14 | `20261008090000_notifications` | 12 | `notifications`, événements par triggers (stock faible, vente importante, invitation, abonnement), `businesses.large_sale_threshold`, publication Realtime |
| ✅ 15 | `20261008100000_audit_hardening` | 13 | `audit_logs.actor_role`, immutabilité (DELETE bloqué sauf purge plateforme), événements emplacements / clients / fournisseurs / produits, RPC `get_audit_log` |
| ✅ 16 | `20261008110000_platform_jobs` | 14 | `billing_events` (idempotence), RPC `platform_activate_subscription` (service_role), `private.daily_maintenance` + `pg_cron` |
| ✅ 17 | `20261008120000_analytics_hardening` | 15 | RPC `get_dashboard_summary`, `get_sales_timeseries`, `get_top_products` ; index `product_costs(business_id)`, `sale_item_costs(business_id, sale_item_id)` |
| ✅ 18 | `20261009090000_platform_admin` | 16 | RBAC plateforme (`platform_admins`, `platform_permissions`, `platform_role_permissions`), helpers `has_platform_permission` / `require_platform_permission`, RPC `admin_*` (entreprises, utilisateurs, abonnements, paiements, audit, analytics, administrateurs), paiement manuel |
| ✅ 20 | `20261010090000_platform_mfa` | 17 | `platform_permissions.requires_mfa`, aal2 exigé pour les actions sensibles et pour tout accès d'un staff enrôlé ; `get_my_platform_access` enrichi |
| ✅ 19 | `20261009100000_support_announcements` | 16 | `support_tickets`, `support_messages` (append-only), `platform_announcements`, RPC `create_support_ticket`, `reply_support_ticket`, `admin_*` support et annonces |
| — | *(futur)* | — | Bucket privé `invoices` (factures PDF générées par Edge Function) — non construit tant que le besoin n'est pas confirmé |

> `audit_logs` est avancé en Phase 4 (au lieu de 13) : les RPC des phases 5–10 doivent
> pouvoir auditer dès leur création. La Phase 13 enrichit et durcit l'audit.

## 3. Types ENUM transverses

| Type | Valeurs |
|---|---|
| `business_status` ✅ | `ACTIVE`, `SUSPENDED` (statut plateforme) |
| `location_type` ✅ | `STORE`, `WAREHOUSE` |
| `member_status` ✅ | `INVITED`, `ACTIVE`, `SUSPENDED` |
| `record_status` ✅ | `ACTIVE`, `ARCHIVED` |
| `inventory_movement_type` ✅ | `INITIAL`, `PURCHASE`, `SALE`, `SALE_CANCELLATION`, `RETURN`, `ADJUSTMENT`, `TRANSFER_OUT`, `TRANSFER_IN`, `LOSS`, `DAMAGE` |
| `sale_status` ✅ | `COMPLETED`, `CANCELLED` |
| `payment_status` ✅ | `UNPAID`, `PARTIAL`, `PAID` |
| `purchase_status` ✅ | `DRAFT`, `ORDERED`, `RECEIVED`, `CANCELLED` |
| `payment_method` ✅ | `CASH`, `WAVE`, `ORANGE_MONEY`, `FREE_MONEY`, `CARD`, `BANK_TRANSFER`, `CHEQUE`, `OTHER` |
| `payment_direction` ✅ | `IN` (encaissement), `OUT` (décaissement) |
| `customer_transaction_type` ✅ | `CREDIT_SALE`, `PAYMENT`, `ADJUSTMENT`, `SALE_CANCELLATION` |
| `subscription_status` ✅ | `TRIALING`, `ACTIVE`, `PAST_DUE`, `CANCELLED`, `EXPIRED` |
| `platform_role` ✅ | `SUPER_ADMIN`, `OPERATIONS`, `SUPPORT`, `FINANCE`, `ANALYST` |
| `platform_admin_status` ✅ | `ACTIVE`, `SUSPENDED` |
| `ticket_status` ✅ | `OPEN`, `IN_PROGRESS`, `WAITING`, `RESOLVED`, `CLOSED` |
| `ticket_priority` ✅ | `LOW`, `NORMAL`, `HIGH`, `URGENT` |
| `announcement_audience` ✅ | `ALL`, `PLAN`, `BUSINESS`, `ROLE` |
| `announcement_status` ✅ | `DRAFT`, `SENT` |

`TRANSFER` est scindé en `TRANSFER_OUT` / `TRANSFER_IN` : un transfert = deux mouvements
liés par `transfer_id`, chacun avec une quantité signée cohérente.

## 4. Tables

Colonnes communes non répétées : `id uuid PK`, `created_at`, `updated_at`.
« Tenant » = porte `business_id uuid NOT NULL` + `UNIQUE (business_id, id)`.

### 4.1 Identité & tenancy (Phases 3-4) ✅

**profiles** — profil applicatif d'un utilisateur Auth (1:1).
- `id uuid PK = auth.users.id` (`ON DELETE CASCADE`), `full_name` (≤ 120), `phone`
  (`^\+?[0-9]{6,15}$`), `avatar_path`, `locale` (`fr` | `en` | `wo`, défaut `fr`).
- Créé par trigger `on_auth_user_created` ; une métadonnée invalide est ignorée et ne bloque
  jamais l'inscription. Aucune donnée d'authentification copiée.
- Lisible/modifiable **par son propriétaire uniquement**. Les noms des collègues passent par
  la RPC `list_business_members`.

**businesses** — l'entreprise (le tenant).
- `name` (2-120, normalisé), `legal_name`, `ninea`, `rccm`, `phone`, `email`, `address`, `city`,
  `country_code` (défaut `SN`), `currency_code` (défaut `XOF`, **non modifiable** par les clients),
  `timezone` (défaut `Africa/Dakar`, validé contre `pg_timezone_names`), `logo_path`,
  `allow_negative_stock` (défaut `false`), `status business_status`, `created_by`.
- Créée uniquement via `create_business()` : entreprise + emplacement par défaut
  « Boutique principale » + membre OWNER + audit, dans une transaction. Limite : 10 entreprises
  possédées par utilisateur (anti-abus). L'abonnement d'essai sera ajouté en Phase 11.
- Toute modification est auditée (`business.update`, champs modifiés avant/après).

**locations** — boutique / dépôt (Tenant).
- `name`, `type location_type`, `address`, `is_default`, `status record_status`.
- Un seul emplacement par défaut par entreprise (index unique partiel), jamais archivé ;
  noms uniques parmi les actifs. `is_default` n'est pas modifiable par les clients.

**business_members** — appartenance (Tenant).
- `user_id`, `role_id`, `status member_status`, `invited_by`, `joined_at`
  (`NULL` ⇔ `INVITED`). `UNIQUE (business_id, user_id)`, index `(user_id)`.
- Écriture **uniquement par RPC**. Le rôle doit être système ou propre à l'entreprise (trigger).
- Invariant (trigger, verrou sur l'entreprise) : **au moins un OWNER actif**, y compris pour
  les rôles privilégiés. La suppression d'un compte Auth qui est le dernier OWNER est donc bloquée.

### 4.2 RBAC (Phase 4) ✅

**permissions** — catalogue global. `code text PK` (`products.read`…), `description`, `module`.

**roles** — `business_id NULL` = rôle système (`OWNER`, `ADMIN`, `MANAGER`, `CASHIER`,
`STOCK_MANAGER`) ; `business_id NOT NULL` = rôle personnalisé futur.
- `code`, `name`, `is_system bool`. Unicité : `(code)` pour les système, `(business_id, code)` sinon (index partiels).

**role_permissions** — `(role_id, permission_code)` PK, `ON DELETE CASCADE` depuis `roles`.

Matrice détaillée : [roles-and-permissions.md](roles-and-permissions.md).

### 4.3 Audit (Phases 4 et 13) ✅

**audit_logs** — journal **immuable**.
- `business_id` (nullable = plateforme), `actor_id` (NULL pour une action plateforme),
  `actor_role` (`authenticated`, `service_role`, `postgres`), `action` (`<domaine>.<verbe>`),
  `resource_type`, `resource_id`, `metadata jsonb` (valeurs avant/après utiles, **jamais de
  secret**), `created_at`.
- Écrit uniquement par `private.log_audit()` (non exécutable par les rôles API).
- `UPDATE` interdit pour **tous** les rôles ; `DELETE` interdit pour tous sauf purge
  plateforme explicite (`set local jendpro.allow_audit_purge = 'on'`, ex. effacement d'une
  entreprise à sa demande).
- Lecture : `audit.read` (OWNER, ADMIN), directement ou via `get_audit_log` (pagination par
  curseur `(created_at, id)`, filtres action/préfixe, ressource, acteur, nom de l'acteur).
- Index `(business_id, created_at DESC, id DESC)`, `(business_id, resource_type, resource_id)`.

Catalogue des actions auditées :

| Domaine | Actions |
|---|---|
| Entreprise | `business.create`, `business.update` (champs modifiés) |
| Emplacements | `location.create`, `location.update`, `location.status_change` |
| Membres | `member.invite`, `member.join`, `member.decline`, `member.role_change`, `member.status_change`, `member.remove`, `member.leave` |
| Catalogue | `product.create`, `product.price_change`, `product.cost_change`, `product.status_change` |
| Stock | `inventory.adjust`, `inventory.count`, `inventory.transfer` |
| Clients | `customer.credit_limit_change`, `customer.payment`, `customer.balance_adjust`, `customer.status_change` |
| Fournisseurs / achats | `supplier.status_change`, `purchase.receive`, `purchase.payment`, `purchase.cancel` |
| Ventes | `sale.discount`, `sale.cancel` |
| Dépenses | `expense.create`, `expense.update`, `expense.delete` |
| Employés | `employee.salary_change` |
| Abonnement | `subscription.change` |

### 4.4 Catalogue (Phase 5) ✅

**categories** (Tenant) — `name`, `parent_id` (FK composite `(business_id, parent_id)`),
`status record_status`.
- **Deux niveaux maximum** (catégorie > sous-catégorie, trigger `CATEGORY_TOO_DEEP`).
- Nom unique (insensible à la casse) parmi les catégories actives d'un même parent.
- CRUD direct (PostgREST) : lecture `products.read`, écriture/suppression `categories.manage`.
  Une catégorie encore utilisée ne peut pas être supprimée (FK) : on l'archive.

**products** (Tenant)
- `category_id` (FK composite, nullable), `name` (1-150), `description`, `sku`, `barcode`
  (normalisés : espaces retirés, vide → NULL), `unit` (texte libre ≤ 20, défaut `pièce`),
  `sale_price bigint ≥ 0`, `track_stock` (défaut `true`, **non modifiable** après création),
  `allows_fractional_quantity` (défaut `false` : quantités entières uniquement),
  `min_stock_level numeric(14,3) ≥ 0`, `image_path`, `status record_status`,
  `created_by` (défaut `auth.uid()`, non fourni par le client).
- `UNIQUE (business_id, sku)`, `UNIQUE (business_id, barcode)` (recherche par code-barres
  servie par cet index).
- `image_path` doit commencer par `{business_id}/` (contrainte `products_image_path_scope_check`).
- Index : `(business_id, name)` (liste triée), `(business_id, category_id)` partiel (filtre + FK).
  `pg_trgm` sur `name` sera ajouté seulement si la recherche le justifie.
- Création/modification directes (`products.create` / `products.update`) ; pas de DELETE ;
  archivage/réactivation via `set_product_status(product_id, status)` (`products.delete`, audité).
- Changement de prix audité (`product.price_change`, ancien/nouveau).

**product_costs** (Tenant) — `product_id` (PK, FK composite vers `products`), `cost_price bigint ≥ 0`.
- Une ligne par produit, **créée automatiquement** (coût 0) à la création du produit.
- Lecture : `products.read_cost` ; modification : `products.read_cost` **et** `products.update`.
  Le caissier ne voit donc ni coûts ni marges.
- Changement audité (`product.cost_change`). Sera recalculé par les réceptions d'achat (CMP, Phase 8).

### 4.5 Inventaire (Phase 6) ✅

**inventory** (Tenant) — stock courant, **cache** du grand livre.
- PK `(business_id, product_id, location_id)`, `quantity numeric(14,3)`, `updated_at`.
  FK composites vers `products` et `locations`. Index `(business_id, location_id)` (écran
  de stock d'un emplacement).
- Pas de `CHECK (quantity >= 0)` : le stock négatif dépend d'un paramètre de l'entreprise
  (`allow_negative_stock`) ; la règle est appliquée par le moteur de stock.
- **Lecture seule** pour les clients (`inventory.read`).

**inventory_movements** (Tenant) — grand livre **append-only** (UPDATE bloqué par trigger
pour tous, aucun droit d'écriture client).
- `product_id`, `location_id`, `type`, `quantity numeric(14,3)` **signée** (≠ 0),
  `quantity_after`, `unit_cost bigint` (coût unitaire au moment du mouvement),
  `reference_type` (`sale` | `purchase` | `adjustment` | `count` | `transfer`), `reference_id`,
  `transfer_id`, `reason`, `created_by` (défaut `auth.uid()`), `created_at`.
- Contraintes : signe imposé par type (`INITIAL`, `PURCHASE`, `SALE_CANCELLATION`, `RETURN`,
  `TRANSFER_IN` > 0 ; `SALE`, `TRANSFER_OUT`, `LOSS`, `DAMAGE` < 0 ; `ADJUSTMENT` ≠ 0),
  `transfer_id` renseigné ⇔ type `TRANSFER_*`, motif obligatoire pour `ADJUSTMENT`, `LOSS`, `DAMAGE`.
- Index : `(business_id, product_id, created_at DESC)` (historique produit),
  `(business_id, created_at DESC)` (journal).

**Moteur de stock** — `private.apply_stock_movement()` est le **seul** code qui écrit ces deux
tables : vérifie produit (même entreprise, `track_stock`, quantités entières), emplacement
(même entreprise, actif), verrouille la ligne de stock (`FOR UPDATE`), refuse le stock négatif
sauf paramètre, met à jour le cache et insère le mouvement dans la même transaction.
Non exécutable par les rôles API ; appelé par les RPC (et plus tard ventes / achats).

**Invariant vérifié par les tests** : `inventory.quantity = Σ inventory_movements.quantity`
pour chaque couple produit × emplacement.

Un emplacement qui détient du stock ne peut pas être archivé (`LOCATION_HAS_STOCK`).

### 4.6 Clients et paiements (Phase 7) ✅

**customers** (Tenant) — `name`, `phone` (espaces/tirets/points retirés), `email`, `address`,
`notes`, `credit_limit bigint` (défaut `0` = pas de crédit ; `NULL` = sans plafond),
`balance bigint ≥ 0` (cache : montant dû), `status`, `created_by` (serveur).
- Création : `customers.create` (sans `credit_limit`, `balance`, `status`) ; modification et
  archivage : `customers.manage` ; plafond : RPC `set_customer_credit_limit` uniquement.
- Un client qui doit de l'argent ne peut pas être archivé (`CUSTOMER_HAS_BALANCE`).
- Index : `(business_id, name)`, `(business_id, phone)`, débiteurs `(business_id, balance DESC) WHERE balance > 0`.

**customer_transactions** (Tenant) — grand livre du compte client, **append-only**.
- `customer_id`, `type`, `amount bigint` signé (+ dette, −  remboursement), `balance_after`,
  `payment_id` (obligatoire ⇔ `PAYMENT`), `note` (obligatoire pour `ADJUSTMENT`), `created_by`.
  La colonne `sale_id` sera ajoutée en Phase 9.
- Signe imposé : `CREDIT_SALE` > 0 ; `PAYMENT`, `SALE_CANCELLATION` < 0 ; `ADJUSTMENT` ≠ 0.
- Index `(business_id, customer_id, created_at DESC)` (relevé client).

**Moteur de compte** — `private.apply_customer_transaction()` : seul écrivain du solde et du
grand livre ; verrouille le client, refuse un solde négatif (`AMOUNT_EXCEEDS_BALANCE`) et, pour
`CREDIT_SALE`, un client archivé ou un dépassement de plafond (`CREDIT_LIMIT_EXCEEDED`).

**Invariant vérifié par les tests** : `customers.balance = Σ customer_transactions.amount`.

### 4.7 Fournisseurs & achats (Phase 8) ✅

**document_sequences** (Tenant, interne) — `(business_id, doc_type)` PK (`SALE` | `PURCHASE`),
`prefix` (`V-` / `A-`), `next_value`. Incrémenté sous verrou par
`private.next_document_number()` → numéros sans doublon par entreprise (`A-000001`).
RLS activée sans aucune policy ni privilège : jamais accessible via l'API.

**suppliers** (Tenant) — `name`, `contact_name`, `phone` (normalisé), `email`, `address`,
`notes`, `status`, `created_by`. CRUD direct : lecture `suppliers.read`, écriture `suppliers.manage`.

**supplier_products** (Tenant) — PK `(supplier_id, product_id)`, FK composites, `supplier_sku`,
`last_cost` (maintenu par la réception, non modifiable par le client).

**purchases** (Tenant) — `number` (unique par entreprise), `supplier_id` (nullable : achat
sans fournisseur enregistré), `location_id` (réception), `status`, `supplier_reference`
(n° de facture fournisseur), `subtotal_amount`, `discount_amount`, `total_amount`,
`amount_paid`, `payment_status` (**colonne générée** à partir de `amount_paid` / `total_amount`),
`ordered_at`, `received_at`/`received_by`, `cancelled_at`/`cancelled_by`/`cancel_reason`, `created_by`.
- CHECK : `total = subtotal − discount`, `amount_paid ≤ total`, cohérence statut ↔ dates.
- **Lecture seule** (`purchases.read`) ; écriture uniquement par RPC.

**purchase_items** (Tenant) — `purchase_id` (CASCADE : lignes remplacées en bloc),
`product_id`, `quantity > 0`, `unit_cost ≥ 0`, `line_total = round(quantity × unit_cost)`.
Un produit une seule fois par achat.

**supplier_balances** (vue, `security_invoker`) — par fournisseur : `amount_due`
(achats reçus non soldés), `advances_paid` (acomptes sur achats en attente), `unpaid_purchases`.

### 4.8 Ventes & paiements (Phase 9) ✅

(`document_sequences` : voir §4.7.)

**sales** (Tenant) — écrite **uniquement** par `create_sale` / `cancel_sale`.
- `number` (`V-000001`, unique par entreprise), `client_reference uuid NOT NULL`
  (`UNIQUE (business_id, client_reference)` : idempotence), `location_id`, `customer_id`
  (nullable), `status`, `subtotal_amount` (Σ lignes après remises de ligne), `discount_amount`
  (remise globale), `total_amount`, `amount_paid` (Σ paiements `IN` à la caisse),
  `credit_amount` (part laissée au compte client), `payment_status` (**générée**), `notes`,
  `sold_at`, `sold_by` (serveur), `cancelled_at` / `cancelled_by` / `cancel_reason`.
- CHECK : `total = subtotal − discount` ; `amount_paid + credit_amount = total` ;
  crédit ⇒ client renseigné ; statut ↔ date d'annulation.
- Index : `(business_id, sold_at DESC)`, `(business_id, customer_id)` partiel,
  `(business_id, sold_by, sold_at DESC)` (ventes du caissier).
- Lecture : `sales.read` (toutes) ou `sales.read_own` (`sold_by = auth.uid()`).

**sale_items** (Tenant) — `sale_id`, `product_id`, `product_name` et `unit_price` **figés**,
`quantity > 0`, `discount_amount` (remise de ligne), `line_total = round(qty × prix) − remise`.
Un produit une fois par vente. Visibles si la vente l'est. Index `(business_id, sale_id)`,
`(business_id, product_id)` (meilleures ventes).

**sale_item_costs** (Tenant) — `sale_item_id` PK, `unit_cost` figé à la vente. Lecture :
`products.read_cost` **et** `sales.read` → le caissier ne voit jamais les marges.

`customer_transactions.sale_id` ✅ : obligatoire ⇔ type `CREDIT_SALE` / `SALE_CANCELLATION`.

**payments** (Tenant) — tout mouvement d'argent. ✅ Socle créé en Phase 7.
- `location_id` (caisse / boutique concernée, obligatoire), `direction`, `method`,
  `amount bigint > 0`, contexte : `customer_id` (règlement de crédit) ✅, `sale_id` ✅,
  `purchase_id` ✅ ; `external_reference` (id Wave/OM, **unique par entreprise et
  méthode** → un webhook rejoué ne crée pas de doublon), `note`, `paid_at`, `recorded_by`.
- `CHECK` : exactement un contexte renseigné (contrainte étendue à chaque phase).
- **Append-only** : un remboursement est un paiement `OUT`, jamais une modification.
- Lecture : `reports.read` (tout) ; règlements clients avec `customers.read` ; paiements
  fournisseurs avec `purchases.read` ; paiements d'une vente si la vente est visible.

### 4.9 Dépenses & employés (Phase 10) ✅

**expense_categories** (Tenant) — `name` (unique parmi les actives), `status`.
10 catégories par défaut créées automatiquement à la création de l'entreprise (trigger
`on_business_created`) : Loyer, Électricité, Eau, Salaires, Transport, Fournitures, Internet
et téléphone, Impôts et taxes, Entretien et réparations, Autres. Lecture `expenses.read`,
gestion `expenses.manage`.

**expenses** (Tenant) — `category_id` (FK composite), `location_id` (nullable = dépense
générale), `amount bigint > 0`, `description`, `spent_on date` (défaut aujourd'hui), `method`,
`receipt_path` (bucket privé `documents`, sous `{business_id}/expenses/`), `created_by` (serveur).
- Création `expenses.create` ; modification et suppression `expenses.manage`.
- **Audit complet** par trigger : `expense.create` (ligne), `expense.update` (avant/après),
  `expense.delete` (ligne supprimée) → une dépense supprimée reste traçable.
- Index `(business_id, spent_on DESC)`, `(business_id, category_id)`.

**employees** (Tenant) — fiche RH, **distincte** du compte de connexion.
- `full_name`, `phone`, `position`, `salary_amount` (mensuel brut), `hired_at`, `ended_at`
  (≥ `hired_at`), `notes`, `status`, `member_id` (lien facultatif vers `business_members`,
  FK composite, unique ; mis à NULL si le membre est retiré).
- Lecture `employees.read` (salaires inclus) ; création/modification `employees.manage` ;
  jamais supprimés (archivage). Changement de salaire audité.

### 4.10 Abonnements (Phase 11) ✅

**subscription_plans** (global, migrations uniquement) — `code` unique, `name`, `description`,
`price_amount`, `currency_code`, `billing_period` (`MONTHLY` | `YEARLY`), `limits jsonb`
(`max_members`, `max_products`, `max_locations` ; `null` = illimité), `features jsonb`,
`is_public`, `sort_order`. Lisibles par tout utilisateur connecté.

| Plan (provisoire) | Prix / mois | Membres | Produits actifs | Emplacements |
|---|---|---|---|---|
| FREE | 0 | 2 | 100 | 1 |
| STARTER | 5 000 | 3 | 500 | 1 |
| PRO (essai) | 10 000 | 10 | 5 000 | 3 |
| BUSINESS | 25 000 | 30 | illimité | 10 |
| ENTERPRISE (non public) | sur devis | illimité | illimité | illimité |

**subscriptions** (Tenant) — historique : `plan_id`, `status`, `trial_ends_at`,
`current_period_start`, `current_period_end` (NULL = sans fin), `cancel_at_period_end`,
`ended_at` (renseigné ⇔ `CANCELLED`/`EXPIRED`), `external_reference`.
- Un seul abonnement **courant** (`TRIALING`/`ACTIVE`/`PAST_DUE`) par entreprise (index unique partiel).
- Écriture : **`service_role` uniquement** ; toute écriture est auditée (`subscription.change`).
- Lecture : membres de l'entreprise.

**billing_events** (interne) — paiements d'abonnement traités : `(provider, event_id)` unique
(idempotence des webhooks), `business_id`, `subscription_id`, `plan_code`, `months`, `amount`.
RLS sans policy ni privilège : accessible uniquement côté serveur.

**permissions.allowed_when_restricted** — permissions conservées en mode restreint
(toutes les lectures, `sales.create`, `sales.credit`, `sales.discount`, `customers.create`,
`customers.payments`, `subscription.manage`).

### 4.11 Notifications (Phase 12) ✅

**notifications** — une ligne **par destinataire** : `business_id` (nullable = plateforme),
`user_id`, `type notification_type` (`LOW_STOCK`, `LARGE_SALE`, `MEMBER_INVITED`,
`SUBSCRIPTION`, `PAYMENT_RECEIVED`, `SYSTEM`), `title`, `body`, `data jsonb`,
`resource_type`, `resource_id`, `read_at`, `created_at`.
- Écrites **uniquement** par la base (`private.notify_user`, `private.notify_members`),
  jamais par les clients (pas d'usurpation).
- Chaque utilisateur lit, marque comme lues (`read_at` seul modifiable) et supprime **ses**
  notifications ; RPC `mark_all_notifications_read(business_id?)`.
- Index `(user_id, created_at DESC)` (centre de notifications), `(user_id) WHERE read_at IS NULL` (badge).
- **Seule table publiée dans Realtime** (`supabase_realtime`) ; la RLS filtre les événements.

| Événement | Déclencheur | Destinataires |
|---|---|---|
| `LOW_STOCK` | mouvement qui fait **franchir** le seuil `min_stock_level` vers le bas | membres actifs avec `inventory.adjust` |
| `LARGE_SALE` | vente dont le total ≥ `businesses.large_sale_threshold` (NULL = désactivé) | membres actifs avec `reports.read` |
| `MEMBER_INVITED` | invitation créée | la personne invitée |
| `SUBSCRIPTION` | abonnement passé `PAST_DUE` ou `EXPIRED` | membres actifs avec `subscription.manage` |

Les destinataires sont résolus sur les **rôles** (indépendamment du mode restreint).

### 4.12 Analytics (Phase 15) ✅

Agrégations calculées **en base** (jamais côté client), permission `reports.read`, marges
seulement avec `products.read_cost` (sinon `null`), dates = jours locaux de l'entreprise
(`businesses.timezone`), période ≤ 366 jours, filtre facultatif par emplacement :

| RPC | Résultat |
|---|---|
| `get_dashboard_summary(business, from, to, location?)` | `revenue`, `sales_count`, `average_basket`, `discounts`, `credit_given`, `cancelled_count`, `active_customers`, `estimated_margin`, `cash_in`, `cash_out`, `expenses`, `net_cash_flow`, `customers_debt`, `low_stock_count` |
| `get_sales_timeseries(business, from, to, 'day'\|'week'\|'month', location?)` | `period`, `revenue`, `sales_count`, `estimated_margin` (périodes vides = 0) |
| `get_top_products(business, from, to, limit?, location?)` | `product_id`, `product_name`, `quantity`, `revenue`, `estimated_margin` |

Définitions : CA = Σ `total_amount` des ventes `COMPLETED` ; marge estimée = Σ (`line_total`
− `quantity × unit_cost` figé) − remises globales ; trésorerie = paiements `IN` − `OUT` − dépenses.
Les montants de `get_top_products` sont par ligne (avant remise globale).

### 4.x Plateforme / back-office (Phase 16) ✅

**platform_admins** (Global) — équipe JËND PRO : `user_id` (PK), `role platform_role`,
`status platform_admin_status`, `created_by`. Indépendant de `business_members` : un membre
du staff n'a **aucun** droit dans les entreprises, et un OWNER n'a aucun droit plateforme.
Lecture : sa propre ligne, ou toutes avec `admins.manage`. Écriture : RPC uniquement.
Invariant : au moins un `SUPER_ADMIN` actif (trigger).

**platform_permissions / platform_role_permissions** (Global, migrations uniquement) —
catalogue et matrice du back-office ([roles-and-permissions.md §6](roles-and-permissions.md#6-back-office-plateforme-phase-16)).

**support_tickets** — `number` (séquence globale), `business_id` (nullable), `created_by`,
`subject`, `status ticket_status`, `priority ticket_priority`, `assigned_to` (staff avec
`support.manage`), `last_message_at`, `resolved_at`, `closed_at`. Lecture : le demandeur, ou
le staff `support.read`. Écriture : RPC uniquement.

**support_messages** — append-only : `ticket_id`, `author_id`, `is_staff`, `is_internal`
(note interne, invisible du demandeur), `body`.

**platform_announcements** — `title`, `body`, `audience`, `audience_value` (code plan,
id entreprise, code rôle), `status` (`DRAFT` → `SENT`), `recipients_count`, `sent_by`,
`sent_at`. Aucun accès API direct ; l'envoi crée des `notifications` `SYSTEM`
(`data.kind = 'ANNOUNCEMENT'`) pour les membres actifs d'entreprises actives de l'audience.

## 5. Index — principes

- Toute FK utilisée en filtre/jointure fréquente est indexée (PostgreSQL ne le fait pas automatiquement).
- Les index composites commencent par `business_id` (toutes les requêtes sont filtrées par tenant).
- Pas d'index « au cas où » : chaque index est justifié par une requête documentée.
- Toute table tenant a un index commençant par `business_id` (garde-fou testé), sauf
  `notifications` (interrogée par `user_id`) et `billing_events` (par identifiant d'événement).
- **Clés étrangères volontairement non indexées** (revue Phase 15) : les colonnes `created_by`
  / `sold_by` / `recorded_by` / `invited_by` / `actor_id` vers `auth.users` (seule la
  suppression d'un compte, opération rare d'administration, en profiterait, au prix d'écritures
  plus lourdes sur les tables les plus actives), et les FK vers des parents jamais supprimés en
  usage normal (`locations`, `sales`, `payments`, `roles`, `subscription_plans`). Les FK
  composites dont la colonne discriminante est déjà indexée (`purchase_items.purchase_id`,
  `employees.member_id`, `supplier_products.supplier_id`…) sont couvertes.
- À volumétrie réelle : suivre `npx supabase inspect db index-stats --linked` (index
  inutilisés) et `... seq-scans --linked`, et ajouter `pg_trgm` sur `products.name` si la
  recherche textuelle devient lente.

## 6. Décisions ouvertes

- **Q1 — Visibilité du coût d'achat.** ✅ *Tranché et implémenté (Phase 5)* : table
  `product_costs` protégée par `products.read_cost`. Les privilèges de colonnes ont été
  écartés : ils s'appliquent à tout `authenticated` quel que soit le rôle métier, et cassent
  les `select('*')` des clients. Le même principe s'appliquera au coût figé des lignes de vente.
- **Q2 — TVA.** V1 : prix TTC, pas de calcul de TVA. Colonnes fiscales ajoutées si besoin
  de facturation normalisée.
