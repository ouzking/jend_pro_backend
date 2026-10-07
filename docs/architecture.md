# Architecture — JËND PRO Backend (V1)

> Statut : **Phase 1 — validée comme cible**. Toute déviation ultérieure doit être
> documentée ici (section « Journal des décisions »).

## 1. Vue d'ensemble

JËND PRO est un SaaS multi-tenant de gestion pour commerces et PME (Sénégal, puis
Afrique de l'Ouest). En V1, **Supabase est l'unique backend** :

```text
 Flutter (mobile)        React (web / back-office)
        │                         │
        └──────────┬──────────────┘
                   │  HTTPS + JWT (anon key + session utilisateur)
                   ▼
 ┌──────────────────────────────────────────────────────────────┐
 │                         Supabase                              │
 │                                                               │
 │  Auth ── JWT ──► PostgREST ──► PostgreSQL (RLS partout)       │
 │                    │              │                           │
 │                    │              ├─ schema public  (tables + │
 │                    │              │   RPC métier exposées)    │
 │                    │              └─ schema private (helpers  │
 │                    │                  sécurité, non exposé)   │
 │  Storage (policies par business_id)                           │
 │  Realtime (notifications, événements de stock ciblés)         │
 │  Edge Functions (Deno) : webhooks paiement, intégrations,     │
 │                          tâches serveur, secrets              │
 └──────────────────────────────────────────────────────────────┘
```

Principes directeurs, par ordre de priorité :

1. **Sécurité et isolation des tenants** garanties par PostgreSQL (RLS), jamais par le client.
2. **Intégrité des données** : contraintes SQL, clés étrangères composites, opérations atomiques.
3. **Logique métier centralisée côté base** (fonctions SQL) et documentée, pour éviter
   qu'elle se disperse dans Flutter/React et pour faciliter la migration Laravel (V2).
4. **Simplicité** : pas de technologie ni de table sans justification.

## 2. Répartition des responsabilités

| Couche | Rôle | Ne fait PAS |
|---|---|---|
| Flutter / React | UI, saisie, cache local, appel de l'API | Sécurité, calculs financiers de référence, décrément de stock |
| PostgREST (lecture/CRUD simple) | Lecture paginée, CRUD des entités simples (catégories, clients, fournisseurs…) protégé par RLS | Opérations multi-tables |
| **RPC SQL (`public.*` fonctions)** | Opérations métier atomiques : vente, annulation, achat/réception, ajustement de stock, règlement de crédit, invitation membre | Appels réseau externes |
| Triggers | Invariants techniques : `updated_at`, audit automatique, limites d'abonnement, protection du dernier OWNER | Logique métier complexe (préférer les RPC explicites) |
| Edge Functions | Secrets, webhooks (Wave, Orange Money…), e-mails/SMS, génération PDF, IA future | Contourner les RPC métier (elles les appellent) |
| Storage | Fichiers (logos, images produits, justificatifs, factures) | — |
| Realtime | Push d'événements à valeur forte (notifications, stock faible) | Diffusion de toutes les tables |

**Règle clé** : toute opération qui modifie plus d'une table de manière couplée
(ex. vente → lignes → stock → mouvements → paiement → audit) est une **fonction SQL
unique exécutée dans une seule transaction**. Le client n'orchestre jamais ces étapes.

## 3. Schémas PostgreSQL

| Schéma | Exposé via API ? | Contenu |
|---|---|---|
| `public` | Oui | Tables métier (toutes avec RLS), vues `security_invoker`, RPC métier appelables par `authenticated` |
| `private` | **Non** | Fonctions helpers `SECURITY DEFINER` (vérification d'appartenance/permissions), fonctions internes de stock, triggers |
| `auth`, `storage` | Géré par Supabase | Identité, fichiers |

Les helpers de sécurité sont `SECURITY DEFINER` + `SET search_path = ''` et vivent dans
`private` pour ne jamais être appelables directement via PostgREST.

Les RPC métier publiques sont `SECURITY DEFINER` uniquement lorsqu'elles doivent écrire
dans des tables non modifiables directement par le client (ex. `inventory`,
`inventory_movements`, `audit_logs`). Elles commencent **toujours** par une vérification
explicite : `private.require_permission(p_business_id, '<permission>')`.

## 4. Stratégie multi-tenant

- **Modèle** : base partagée, schéma partagé, colonne `business_id` sur chaque table
  métier (« pool model »). C'est le modèle adapté à des milliers de petites entreprises.
- **Appartenance** : `business_members (business_id, user_id, role_id, status)`.
  Un utilisateur peut appartenir à **plusieurs** entreprises ; aucune hypothèse
  « 1 utilisateur = 1 entreprise ».
- **Contexte actif** : le client envoie explicitement le `business_id` (filtres et
  paramètres RPC). La RLS vérifie l'appartenance à chaque requête. Pas de
  « business courant » stocké dans le JWT en V1 (évite les JWT périmés après
  changement de rôle).
- **Intégrité inter-tenant par clés étrangères composites** : chaque table tenant
  expose `UNIQUE (business_id, id)` et les tables enfants référencent
  `(business_id, <parent>_id)`. Il devient **physiquement impossible** de lier une
  ligne de vente de l'entreprise A à un produit de l'entreprise B, même en cas de bug
  dans une fonction `SECURITY DEFINER`.
- **Default deny**, en deux couches :
  1. **Privilèges** : aucun droit implicite pour `anon`/`authenticated` sur les tables et
     fonctions (default privileges révoqués dans la migration `foundation`). Chaque table
     accorde explicitement les opérations — et si besoin les colonnes — autorisées.
  2. **RLS** activée sur toutes les tables `public` ; aucune policy = aucun accès.
  La RLS n'est pas `FORCE` : les fonctions `SECURITY DEFINER` (propriétaire `postgres`)
  doivent pouvoir écrire dans les tables internes ; leur sécurité repose sur la
  vérification explicite de permission (voir [security.md §4](security.md#4-rpc-security-definer--checklist-obligatoire)).

Détails : [security.md](security.md).

## 5. Données de référence vs données tenant

| Type | Exemples | `business_id` | Écriture |
|---|---|---|---|
| Globales | `permissions`, `subscription_plans`, rôles système | NULL / absent | Migrations / service_role uniquement |
| Tenant | produits, ventes, clients… | NOT NULL | Membres autorisés (RLS + RPC) |
| Utilisateur | `profiles`, notifications personnelles | via `user_id` | Propriétaire de la ligne |

## 6. Organisation du dépôt

```text
jend_pro_backend/
├── supabase/
│   ├── config.toml            # généré par `supabase init` (Phase 2)
│   ├── migrations/            # SQL versionné, ordonné, jamais réécrit une fois appliqué
│   ├── functions/             # Edge Functions Deno (une fonction = un dossier)
│   │   └── _shared/           # code partagé (client Supabase, erreurs, CORS)
│   ├── seed.sql               # données de dev locales uniquement (jamais en prod)
│   └── tests/
│       └── database/          # tests pgTAP (`supabase test db`)
├── docs/
│   ├── architecture.md        # ce document
│   ├── database.md            # modèle de données
│   ├── security.md            # RLS, Storage, secrets
│   ├── roles-and-permissions.md
│   ├── business-rules.md      # règles métier + stratégie financière
│   └── migration-to-laravel.md
└── README.md
```

> Note : la CLI Supabase attend `supabase/seed.sql` (configurable via
> `[db.seed].sql_paths`). On utilisera `supabase/seed.sql` ou `supabase/seed/*.sql`
> déclaré dans `config.toml` — décision prise en Phase 2.

## 7. Conventions

### 7.1 Nommage SQL
- Tables : `snake_case`, **pluriel** (`products`, `sale_items`).
- Colonnes : `snake_case` ; FK = `<entité_singulier>_id` (`product_id`).
- Clé primaire : `id uuid DEFAULT gen_random_uuid()`.
- Horodatage : `created_at timestamptz NOT NULL DEFAULT now()`,
  `updated_at timestamptz NOT NULL DEFAULT now()` (trigger `private.set_updated_at`).
- Auteur : `created_by uuid REFERENCES auth.users(id)` lorsque pertinent
  (valeur imposée côté serveur via `auth.uid()`, jamais fournie par le client).
- Montants : `bigint` en unités entières de la devise (XOF = francs entiers),
  suffixe explicite si ambigu (`unit_price`, `total_amount`). **Jamais de float.**
- Quantités : `numeric(14,3)` (vente au kilo/litre possible).
- Contraintes nommées : `<table>_<colonne>_check`, `<table>_<cols>_key`, `<table>_<col>_fkey`.
- Index : `<table>_<cols>_idx`.
- Policies RLS : phrase lisible, ex. `"members with products.read can select"`.
- Fonctions RPC : verbe + objet (`create_sale`, `cancel_sale`, `adjust_stock`).
  Paramètres préfixés `p_`, variables `v_`.

### 7.2 Types énumérés
- Ensembles **fermés et stables** (statut de vente, type de mouvement, méthode de
  paiement) : **ENUM PostgreSQL** → types générés propres pour Flutter/TypeScript.
- Ensembles **configurables par le métier** (catégories de dépenses, unités) : **table**.
- Ajout de valeur à un ENUM = nouvelle migration `ALTER TYPE ... ADD VALUE`.
  Retrait de valeur interdit (on déprécie).

### 7.3 Migrations
- Nom : `YYYYMMDDHHMMSS_<domaine>_<description>.sql` (généré par `supabase migration new`).
- Une migration = un sujet cohérent. Chaque migration crée tables **+ RLS + policies
  + index + grants** ensemble : **aucune table n'existe jamais sans RLS**.
- Une migration appliquée (local partagé, staging ou prod) n'est **jamais modifiée** :
  on ajoute une nouvelle migration.
- Idempotence quand c'est sûr (`CREATE EXTENSION IF NOT EXISTS`, `CREATE OR REPLACE FUNCTION`) ;
  pas de `IF NOT EXISTS` sur les tables (masquerait une dérive de schéma).
- Pas de modification de schéma via le Dashboard. Si une dérive est détectée :
  `supabase db diff` → nouvelle migration.

### 7.4 Suppression
- Entités référencées par de l'historique (produits, clients, fournisseurs) :
  **archivage** (`status = 'ARCHIVED'` / `archived_at`), pas de `DELETE`.
- Écritures financières et mouvements (ventes, paiements, mouvements de stock,
  transactions client, audit) : **append-only** ; on corrige par une écriture inverse.
- FK par défaut `ON DELETE RESTRICT` ; `CASCADE` uniquement pour des enfants purs
  (ex. `role_permissions`) — chaque `CASCADE` est justifié en commentaire.

### 7.5 Pagination et API
- Pagination par **keyset** (`created_at, id`) pour les historiques volumineux
  (ventes, mouvements), `range()` acceptable pour les petites listes.
- Agrégations (dashboard, rapports) via RPC/vues SQL, jamais calculées côté client
  sur des listes complètes.

### 7.6 Fuseau horaire
- Stockage en `timestamptz` (UTC). `businesses.timezone` (défaut `Africa/Dakar`)
  utilisé pour les regroupements « par jour » des rapports.

## 8. Décisions d'architecture (ADR courtes)

| # | Décision | Justification |
|---|---|---|
| D1 | RLS + tables et RPC créées ensemble, domaine par domaine | Évite toute fenêtre où une table existe sans protection (le découpage « schéma complet puis RLS » est rejeté) |
| D2 | Montants en `bigint` (unités entières de devise) | XOF n'a pas de subdivision (ISO 4217 : 0 décimale) ; exact, rapide, pas d'erreur d'arrondi |
| D3 | Stock = cache `inventory` + grand livre `inventory_movements` append-only | Lecture rapide du stock courant + traçabilité complète ; écrit uniquement par fonctions |
| D4 | Notion d'emplacement (`locations`) dès la V1, une emplacement par défaut créé automatiquement | Les transferts (`TRANSFER`) et le multi-boutique sont très fréquents chez les PME ; ajouter la dimension plus tard imposerait une migration lourde du stock |
| D5 | FK composites `(business_id, id)` | Isolation des tenants garantie par le schéma, pas seulement par les policies |
| D6 | RBAC en tables (`roles`, `permissions`, `role_permissions`) avec rôles système | Évolutif (rôles personnalisés futurs) sans changer le code |
| D7 | Idempotence des ventes via `client_reference` (uuid fourni par le client) | Réseaux mobiles instables : un retry ne doit jamais créer deux ventes |
| D8 | Numérotation séquentielle par entreprise (`document_sequences`) | Numéros de ticket/facture lisibles et sans trou par entreprise |
| D9 | Pas de Laravel, Redis, file de messages en V1 | Supabase couvre le besoin ; à réévaluer en V2 |
| D10 | Abonnements modifiables uniquement par `service_role` (Edge Function / webhook) | Un client ne doit jamais pouvoir s'auto-attribuer un plan |

## 9. Journal des décisions

| Date | Décision | Auteur |
|---|---|---|
| 2026-10-07 | Architecture cible V1 (ce document) | Phase 1 |
| 2026-10-07 | **Coûts d'achat masqués** aux rôles sans `products.read_cost` (caissier). Mécanisme précis choisi en Phase 5 | Phase 2 |
| 2026-10-07 | **Abonnement expiré** : lecture seule, mais la caisse (ventes, règlements) reste ouverte | Phase 2 |
| 2026-10-07 | **Images produits et logos** en lecture publique (URL non devinable) ; justificatifs et factures privés | Phase 2 |
| 2026-10-07 | **Caissier** autorisé à vendre à crédit et à encaisser les règlements de crédit | Phase 2 |
| 2026-10-07 | **Privilèges explicites** : default privileges révoqués pour `anon`/`authenticated` ; RLS non forcée | Phase 2 |
| 2026-10-07 | Seed de dev : `supabase/seed.sql` (emplacement par défaut de la CLI) ; tests : `supabase/tests/database/*.sql` | Phase 2 |
