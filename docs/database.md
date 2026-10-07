# Modèle de données — JËND PRO

> Statut : **modèle cible (Phase 1)**. Chaque table est implémentée dans la phase
> indiquée ; ce document est mis à jour à chaque phase pour refléter le schéma réel.
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
| 01 | `foundation` | 2 | Extensions, schéma `private`, révocations par défaut, `set_updated_at()`, types ENUM transverses, utilitaires de test |
| 02 | `identity_tenancy` | 3 | `profiles`, `businesses`, `locations`, `business_members`, trigger création profil, RPC `create_business` |
| 03 | `rbac` | 4 | `permissions`, `roles`, `role_permissions`, seeds système, helpers `private.has_permission`, RLS des tables Phase 3 durcies |
| 04 | `audit` | 4 | `audit_logs` + `private.log_audit()` (nécessaire dès les premières opérations sensibles) |
| 05 | `catalog` | 5 | `categories`, `units` (optionnel), `products` |
| 06 | `inventory` | 6 | `inventory`, `inventory_movements`, fonctions internes de stock, RPC `adjust_stock`, `transfer_stock` |
| 07 | `customers` | 7 | `customers`, `customer_transactions`, RPC `record_customer_payment` |
| 08 | `suppliers_purchases` | 8 | `suppliers`, `supplier_products`, `purchases`, `purchase_items`, RPC `create_purchase`, `receive_purchase` |
| 09 | `sales_payments` | 9 | `document_sequences`, `sales`, `sale_items`, `payments`, RPC `create_sale`, `cancel_sale` |
| 10 | `expenses` | 10 | `expense_categories`, `expenses` |
| 11 | `employees` | 10 | `employees` |
| 12 | `subscriptions` | 11 | `subscription_plans`, `subscriptions`, triggers de limites |
| 13 | `notifications` | 12 | `notifications`, publication Realtime |
| 14 | `storage` | 5→10 | Buckets + policies (ajoutés au fil des besoins) |
| 15 | `analytics` | 15 | Vues / RPC de reporting, index complémentaires |

> `audit_logs` est avancé en Phase 4 (au lieu de 13) : les RPC des phases 5–10 doivent
> pouvoir auditer dès leur création. La Phase 13 enrichit et durcit l'audit.

## 3. Types ENUM transverses

| Type | Valeurs |
|---|---|
| `member_status` | `INVITED`, `ACTIVE`, `SUSPENDED` |
| `record_status` | `ACTIVE`, `ARCHIVED` |
| `inventory_movement_type` | `INITIAL`, `PURCHASE`, `SALE`, `RETURN`, `ADJUSTMENT`, `TRANSFER_IN`, `TRANSFER_OUT`, `LOSS`, `DAMAGE`, `SALE_CANCELLATION` |
| `sale_status` | `COMPLETED`, `CANCELLED` |
| `payment_status` | `UNPAID`, `PARTIAL`, `PAID` |
| `purchase_status` | `DRAFT`, `ORDERED`, `RECEIVED`, `CANCELLED` |
| `payment_method` | `CASH`, `WAVE`, `ORANGE_MONEY`, `FREE_MONEY`, `CARD`, `BANK_TRANSFER`, `CHEQUE`, `OTHER` |
| `payment_direction` | `IN` (encaissement), `OUT` (décaissement) |
| `customer_transaction_type` | `CREDIT_SALE`, `PAYMENT`, `ADJUSTMENT`, `SALE_CANCELLATION` |
| `subscription_status` | `TRIALING`, `ACTIVE`, `PAST_DUE`, `CANCELLED`, `EXPIRED` |

`TRANSFER` est scindé en `TRANSFER_OUT` / `TRANSFER_IN` : un transfert = deux mouvements
liés par `transfer_id`, chacun avec une quantité signée cohérente.

## 4. Tables

Colonnes communes non répétées : `id uuid PK`, `created_at`, `updated_at`.
« Tenant » = porte `business_id uuid NOT NULL` + `UNIQUE (business_id, id)`.

### 4.1 Identité & tenancy (Phase 3)

**profiles** — profil applicatif d'un utilisateur Auth (1:1).
- `id uuid PK = auth.users.id` (`ON DELETE CASCADE`), `full_name`, `phone`, `avatar_path`,
  `locale` (défaut `fr`), `last_business_id` (préférence UI uniquement, jamais utilisée pour la sécurité).
- Créé par trigger sur `auth.users` (INSERT). Aucune donnée d'authentification (mot de passe, tokens).

**businesses** — l'entreprise (le tenant).
- `name`, `slug` (unique), `legal_name`, `ninea` (identifiant fiscal SN, optionnel),
  `rccm`, `phone`, `email`, `address`, `city`, `country_code char(2)` défaut `SN`,
  `currency_code char(3)` défaut `XOF`, `timezone` défaut `Africa/Dakar`,
  `logo_path`, `allow_negative_stock bool` défaut `false`, `status`, `created_by`.
- Créée uniquement via RPC `create_business` (crée aussi le membre OWNER, l'emplacement
  par défaut et l'abonnement FREE/essai dans la même transaction).

**locations** — boutique / dépôt d'une entreprise (Tenant).
- `name`, `type` (`STORE`/`WAREHOUSE`), `address`, `is_default bool`, `status`.
- Index unique partiel : un seul `is_default = true` par entreprise.

**business_members** — appartenance d'un utilisateur à une entreprise (Tenant).
- `user_id → auth.users`, `role_id → roles`, `status member_status`,
  `invited_by`, `invited_email`, `joined_at`.
- `UNIQUE (business_id, user_id)`. Index `(user_id)` pour « mes entreprises ».
- Invariant (trigger) : une entreprise a toujours **au moins un OWNER actif**.

### 4.2 RBAC (Phase 4)

**permissions** — catalogue global. `code text PK` (`products.read`…), `description`, `module`.

**roles** — `business_id NULL` = rôle système (`OWNER`, `ADMIN`, `MANAGER`, `CASHIER`,
`STOCK_MANAGER`) ; `business_id NOT NULL` = rôle personnalisé futur.
- `code`, `name`, `is_system bool`. Unicité : `(code)` pour les système, `(business_id, code)` sinon (index partiels).

**role_permissions** — `(role_id, permission_code)` PK, `ON DELETE CASCADE` depuis `roles`.

Matrice détaillée : [roles-and-permissions.md](roles-and-permissions.md).

### 4.3 Audit (Phase 4, enrichi Phase 13)

**audit_logs** — append-only.
- `business_id` (nullable pour événements plateforme), `actor_id` (nullable si système),
  `action` (`sale.cancel`, `member.role_change`…), `resource_type`, `resource_id`,
  `metadata jsonb` (diff minimal, **sans données sensibles**), `created_at`.
- Aucune policy INSERT/UPDATE/DELETE pour `authenticated` : écrit uniquement par
  `private.log_audit()`. Index `(business_id, created_at DESC)`, `(business_id, resource_type, resource_id)`.

### 4.4 Catalogue (Phase 5)

**categories** (Tenant) — `name`, `parent_id` (FK composite, 1 niveau d'imbrication conseillé), `status`.
`UNIQUE (business_id, lower(name))` sur les actives.

**products** (Tenant)
- `category_id` (FK composite, nullable), `name`, `description`, `sku`, `barcode`,
  `unit` (`pièce`, `kg`, `litre`… texte contrôlé), `sale_price bigint ≥ 0`,
  `cost_price bigint ≥ 0` *(voir décision ouverte Q1)*, `track_stock bool` défaut `true`,
  `min_stock_level numeric(14,3) ≥ 0`, `image_path`, `status record_status`, `created_by`.
- Unicités partielles : `(business_id, sku)` et `(business_id, barcode)` quand non NULL.
- Index : `(business_id, status, name)` pour la liste, recherche texte via
  `pg_trgm` sur `name` *(ajouté seulement si la recherche le justifie)*.

### 4.5 Inventaire (Phase 6)

**inventory** (Tenant) — stock courant, **cache** du grand livre.
- PK `(business_id, product_id, location_id)`, `quantity numeric(14,3)`, `updated_at`.
- `CHECK (quantity >= 0)` contournable uniquement si `businesses.allow_negative_stock`
  (vérifié dans la fonction de mouvement, la contrainte devient conditionnelle via trigger).
- **Aucune écriture directe** par le client.

**inventory_movements** (Tenant) — grand livre append-only.
- `product_id`, `location_id`, `type inventory_movement_type`,
  `quantity numeric(14,3)` **signée** (+ entrée / − sortie, ≠ 0),
  `quantity_after numeric(14,3)`, `unit_cost bigint` (valorisation),
  `reference_type` (`sale`, `purchase`, `adjustment`, `transfer`), `reference_id`,
  `transfer_id`, `reason text`, `created_by`, `created_at`.
- Contrainte de signe par type (ex. `SALE` < 0, `PURCHASE` > 0).
- Index : `(business_id, product_id, created_at DESC)`, `(business_id, created_at DESC)`.
- Écrit **uniquement** par `private.apply_stock_movement()` qui verrouille la ligne
  `inventory` (`SELECT … FOR UPDATE`), contrôle le stock négatif, met à jour le cache et
  insère le mouvement dans la même transaction.

### 4.6 Clients (Phase 7)

**customers** (Tenant) — `name`, `phone`, `email`, `address`, `notes`,
`credit_limit bigint` (défaut `0` = pas de crédit ; `NULL` = sans plafond ; voir business-rules),
`balance bigint` (cache : montant dû par le client, ≥ 0 normalement), `status`.
Index `(business_id, phone)`, `(business_id, name)`.

**customer_transactions** (Tenant) — grand livre du compte client, append-only.
- `customer_id`, `type customer_transaction_type`, `amount bigint` signé
  (+ augmente la dette, − la diminue), `balance_after bigint`, `sale_id`, `payment_id`,
  `note`, `created_by`.

### 4.7 Fournisseurs & achats (Phase 8)

**suppliers** (Tenant) — `name`, `phone`, `email`, `address`, `contact_name`, `notes`, `status`.

**supplier_products** (Tenant) — `(business_id, supplier_id, product_id)` unique,
`supplier_sku`, `last_cost bigint`.

**purchases** (Tenant) — `number` (séquence), `supplier_id`, `location_id` (réception),
`status purchase_status`, `ordered_at`, `received_at`, `subtotal_amount`,
`discount_amount`, `total_amount`, `amount_paid`, `payment_status`, `notes`, `created_by`.
Dette fournisseur = `total_amount − amount_paid` (vue `supplier_balances`).

**purchase_items** (Tenant) — `purchase_id`, `product_id`, `quantity > 0`, `unit_cost ≥ 0`,
`line_total`. La **réception** (`receive_purchase`) génère les mouvements `PURCHASE`.

### 4.8 Ventes & paiements (Phase 9)

**document_sequences** (Tenant) — `(business_id, doc_type)` PK, `prefix`, `next_value`.
Incrément sous verrou de ligne → numéros sans doublon par entreprise.

**sales** (Tenant)
- `number` (ex. `V-000123`), `client_reference uuid` (idempotence, `UNIQUE (business_id, client_reference)`),
  `location_id`, `customer_id` (nullable), `status sale_status`,
  `subtotal_amount`, `discount_amount`, `total_amount`, `amount_paid`,
  `credit_amount` (part à crédit), `payment_status`, `sold_at`, `sold_by`,
  `cancelled_at`, `cancelled_by`, `cancel_reason`.
- `CHECK (total_amount = subtotal_amount - discount_amount)`,
  `CHECK (amount_paid + credit_amount = total_amount)` (hors rendu monnaie).
- Index : `(business_id, sold_at DESC)`, `(business_id, customer_id)`, `(business_id, sold_by, sold_at DESC)`.

**sale_items** (Tenant) — `sale_id`, `product_id`, `product_name` (copie figée),
`quantity > 0`, `unit_price`, `unit_cost` (copie figée pour la marge), `discount_amount`, `line_total`.

**payments** (Tenant) — tout mouvement d'argent.
- `direction payment_direction`, `method payment_method`, `amount bigint > 0`,
  `sale_id` | `purchase_id` | `customer_id` (règlement de crédit) | `expense_id`,
  `external_reference` (id transaction Wave/OM, unique par entreprise et méthode),
  `paid_at`, `recorded_by`. Append-only : un remboursement est un paiement `OUT`.
- `CHECK` : exactement un contexte renseigné.

### 4.9 Dépenses & employés (Phase 10)

**expense_categories** (Tenant) — `name`, `status` (catégories par défaut créées à l'ouverture).

**expenses** (Tenant) — `category_id`, `amount bigint > 0`, `description`, `spent_at date`,
`location_id`, `method payment_method`, `receipt_path` (Storage `documents`), `created_by`.

**employees** (Tenant) — fiche RH, **distincte** du compte Auth.
- `full_name`, `phone`, `position`, `salary_amount bigint`, `hired_at`, `status`,
  `member_id` (nullable → `business_members` : l'employé a un accès à l'app).

### 4.10 Abonnements (Phase 11)

**subscription_plans** (global) — `code` (`FREE`, `STARTER`, `PRO`, `BUSINESS`, `ENTERPRISE`),
`name`, `price_amount bigint`, `currency_code`, `billing_period` (`MONTHLY`/`YEARLY`),
`limits jsonb` (`max_members`, `max_products`, `max_locations`…), `features jsonb`, `is_public`.

**subscriptions** (Tenant) — `plan_id`, `status subscription_status`,
`current_period_start`, `current_period_end`, `trial_ends_at`, `cancelled_at`,
`external_reference`. Index unique partiel : un abonnement non terminé par entreprise.
Écriture : `service_role` uniquement.

### 4.11 Notifications (Phase 12)

**notifications** — `business_id` (nullable pour notifications plateforme),
`user_id` (destinataire), `type` (`LOW_STOCK`, `LARGE_SALE`, `PAYMENT_RECEIVED`,
`SUBSCRIPTION`…), `title`, `body`, `data jsonb`, `resource_type`, `resource_id`, `read_at`.
Index `(user_id, read_at, created_at DESC)`. Publiée dans Realtime.

## 5. Index — principes

- Toute FK utilisée en filtre/jointure fréquente est indexée (PostgreSQL ne le fait pas automatiquement).
- Les index composites commencent par `business_id` (toutes les requêtes sont filtrées par tenant).
- Pas d'index « au cas où » : chaque index est justifié par une requête documentée.
- Vérification en Phase 15 via `supabase inspect db` (index inutilisés, seq scans).

## 6. Décisions ouvertes

- **Q1 — Visibilité du coût d'achat.** La RLS est par ligne, pas par colonne. Si les
  caissiers ne doivent pas voir `cost_price` / les marges, il faut isoler le coût
  (table `product_costs` ou vue sans coût + permission `products.read_cost`).
  À trancher avant la Phase 5.
- **Q2 — TVA.** V1 : prix TTC, pas de calcul de TVA. Colonnes fiscales ajoutées si besoin
  de facturation normalisée.
