# Sécurité — JËND PRO Backend

> Principe : **DEFAULT DENY + EXPLICIT ALLOW**, appliqué par PostgreSQL.
> Flutter et React ne sont **jamais** une couche de sécurité.

## 1. Modèle de menace (résumé)

| Menace | Contre-mesure |
|---|---|
| Un membre de l'entreprise A lit/modifie les données de B | RLS sur `business_id` + FK composites `(business_id, id)` |
| Escalade de rôle (caissier → admin) | `business_members` modifiable uniquement via RPC contrôlée ; un rôle ne peut attribuer un rôle supérieur au sien ; OWNER protégé |
| Requête forgée directement contre PostgREST (contourne l'UI) | Toutes les règles sont en RLS/RPC ; l'UI n'en est qu'un reflet |
| Fonction `SECURITY DEFINER` mal écrite qui fuit des données | `search_path = ''`, vérification de permission en première instruction, FK composites, tests |
| Auto-attribution d'un abonnement payant | Écriture des abonnements réservée à `service_role` |
| Falsification de l'auteur (`created_by`) ou du prix | Valeurs imposées côté serveur (`auth.uid()`, prix lus en base dans les RPC) |
| Rejeu d'une vente (réseau instable) | `client_reference` unique par entreprise |
| Fuite de secrets | Aucun secret dans Git ; `service_role` uniquement dans Edge Functions ; `.gitignore` |
| Accès aux fichiers d'un autre tenant | Policies Storage sur le préfixe `business_id/` |
| Données sensibles dans les logs | `audit_logs.metadata` limité aux champs utiles ; jamais de token, mot de passe, numéro complet de carte |

## 2. Clés et rôles Supabase

| Clé / rôle | Où | Pouvoir |
|---|---|---|
| `anon` (publishable key) | Flutter, React | Aucun accès aux données métier (aucune policy pour `anon`) |
| `authenticated` (JWT utilisateur) | Flutter, React après login | Soumis à la RLS |
| `service_role` (secret key) | **Edge Functions uniquement** (variable d'environnement) | Bypass RLS — jamais dans un client, jamais dans Git |

### 2.1 Équipe plateforme (back-office, Phase 16)

Le back-office React s'exécute dans un navigateur : il utilise la clé **publishable** et le JWT
du membre du staff, **jamais** `service_role`. Les droits plateforme viennent de
`platform_admins` et sont vérifiés en base par `private.require_platform_permission()` en
tête de chaque RPC `admin_*` ; aucune policy des tables des entreprises n'est élargie. Les
actions sensibles (suspension, paiement manuel, gestion du staff, tickets, annonces) sont
auditées (`business.status_change`, `billing.manual_payment`, `platform_admin.*`,
`support.ticket_update`, `announcement.send`). Recommandé en production : MFA (TOTP) pour
les comptes du staff (Dashboard → Auth).

## 3. RLS — règles de conception

1. `ALTER TABLE … ENABLE ROW LEVEL SECURITY` **dans la même migration** que le `CREATE TABLE`.
2. Aucune policy pour `anon` sur les tables métier.
3. Une policy par opération (`SELECT`, `INSERT`, `UPDATE`, `DELETE`) et par rôle Postgres
   (`TO authenticated`), jamais `FOR ALL` implicite.
4. `UPDATE` a toujours `USING` **et** `WITH CHECK` (empêche de « déplacer » une ligne vers un autre tenant).
5. Pas de policy `INSERT/UPDATE/DELETE` sur les tables écrites par fonctions
   (`inventory`, `inventory_movements`, `audit_logs`, `customer_transactions`, `payments`,
   `sales`, `sale_items`…) : le seul chemin d'écriture est la RPC métier.
6. `business_id` n'est jamais modifiable après insertion (trigger d'immuabilité ou `WITH CHECK`).

### 3.1 Helpers (schéma `private`, non exposé)

```sql
-- Vrai si l'utilisateur courant est membre ACTIF de l'entreprise.
private.is_member(p_business_id uuid) returns boolean

-- Vrai si le rôle du membre actif possède la permission.
private.has_permission(p_business_id uuid, p_permission text) returns boolean

-- Ensemble des entreprises où l'utilisateur a la permission (pour RLS performante).
private.businesses_with_permission(p_permission text) returns setof uuid

-- Lève une exception 42501 si la permission manque (utilisé en tête des RPC).
private.require_permission(p_business_id uuid, p_permission text) returns void
```

Tous : `LANGUAGE sql|plpgsql STABLE SECURITY DEFINER SET search_path = ''`, exécutables par
`authenticated` uniquement (nécessaire à l'évaluation des policies). Le schéma `private`
n'est pas exposé par PostgREST (vérifié : `PGRST106 Invalid schema: private`).
`SECURITY DEFINER` évite la récursion RLS sur `business_members`.

### 3.2 Forme type d'une policy (performante)

```sql
create policy "members with products.read can select"
  on public.products for select to authenticated
  using (business_id in (select private.businesses_with_permission('products.read')));
```

Le sous-select est évalué **une fois par requête** (InitPlan) et non une fois par ligne :
c'est la recommandation Supabase pour la performance RLS à grande échelle. Les
colonnes utilisées (`business_id`) sont en tête des index.

### 3.3 Cas particuliers
- **profiles** : chacun lit/modifie **uniquement** son profil (colonnes `full_name`, `phone`,
  `avatar_path`, `locale`). L'annuaire des collègues passe par `list_business_members()` :
  nom/avatar/rôle des membres actifs pour tout membre ; e-mail, téléphone, invités et suspendus
  seulement avec `members.read`.
- **businesses** : lecture si membre actif d'une entreprise active ; mise à jour d'une liste
  fermée de colonnes si `settings.manage` (ni `currency_code`, ni `status`, ni `created_by`) ;
  création via RPC uniquement ; pas de DELETE client.
- **business_members** : lecture de ses propres lignes (dont invitations) ou de toutes avec
  `members.read` ; aucune écriture directe — RPC `invite_member`, `accept_invitation`,
  `decline_invitation`, `change_member_role`, `set_member_status`, `remove_member`, `leave_business`.
- **Hiérarchie** : on ne peut attribuer, modifier, suspendre ou retirer qu'un rôle dont les
  permissions sont **incluses** dans les siennes (un ADMIN ne peut jamais toucher un OWNER) ;
  personne ne modifie son propre rôle ou statut.
- **Statuts** : seuls les membres `ACTIVE` d'entreprises `ACTIVE` ont des droits (suspension immédiate).
- **notifications** : lecture/marquage lu par le destinataire uniquement (`user_id = auth.uid()`).
- **sales (caissier)** : `sales.read` → toutes les ventes ; `sales.read_own` → seulement `sold_by = auth.uid()`.

## 4. RPC `SECURITY DEFINER` — checklist obligatoire

- [ ] `SET search_path = ''` et noms qualifiés (`public.products`).
- [ ] Première instruction : `perform private.require_permission(p_business_id, '…');`
- [ ] Toute entité référencée est relue avec `WHERE business_id = p_business_id`.
- [ ] Prix, coûts, totaux recalculés côté serveur ; les montants fournis par le client sont ignorés ou vérifiés.
- [ ] `auth.uid()` utilisé pour `created_by` / `sold_by`.
- [ ] Verrous (`FOR UPDATE`) sur les lignes de stock / séquences / soldes modifiées.
- [ ] Audit via `private.log_audit()`.
- [ ] `REVOKE EXECUTE … FROM public, anon; GRANT EXECUTE … TO authenticated;`
- [ ] Erreurs métier avec `SQLSTATE` et message stables (le client les mappe), sans fuite d'information sur d'autres tenants.

> Supabase accorde par défaut `EXECUTE` à `anon` sur les nouvelles fonctions du schéma
> `public`. La migration de fondation modifie les **default privileges** pour révoquer
> ce droit, et chaque fonction déclare explicitement ses grants.

## 5. Storage

| Bucket | Public ? | Chemin | Lecture | Écriture |
|---|---|---|---|---|
| `business-assets` ✅ | Lecture publique par URL | `{business_id}/logo.*` | URL : tous ; listing API : membres | `settings.manage` |
| `product-images` ✅ | Lecture publique par URL | `{business_id}/{product_id}/*` | URL : tous ; listing API : `products.read` | `products.update` (upload, remplacement, suppression) |
| `documents` ✅ | **Privé** (URL signées) | `{business_id}/expenses/…` (autres dossiers à venir) | `expenses.read` | upload `expenses.create`, remplacement/suppression `expenses.manage` — JPEG/PNG/WebP/PDF ≤ 5 Mo |
| `invoices` | **Privé** | `{business_id}/{sale_id}.pdf` | `sales.read` | Edge Function (`service_role`) |

Policies sur `storage.objects` basées sur `private.storage_business_id(name)` (premier
segment du chemin s'il s'agit d'un UUID, sinon NULL → aucune policy ne correspond) et
`private.businesses_with_permission(...)`. Limites : 2 Mo (`product-images`), 1 Mo
(`business-assets`) ; types `image/jpeg`, `image/png`, `image/webp` uniquement — **SVG
interdit** (risque d'injection de script sur un domaine public). Les colonnes `image_path` /
`logo_path` doivent pointer dans le dossier de l'entreprise (contraintes CHECK).
Fichiers privés servis par **URL signées** à durée courte.

Vérifié de bout en bout via l'API Storage (2026-10-07) : upload owner accepté, upload et
suppression caissier refusés (403), SVG refusé (415), lecture publique par URL (200).
Note de test : Storage interdit les `DELETE` SQL directs (`storage.protect_delete`) ; les tests
pgTAP positionnent `storage.allow_delete_query` comme le fait l'API pour tester les policies.

> Décision (2026-10-07) : images produits et logos en lecture publique (performance, CDN,
> données non sensibles). Si un client exige un catalogue confidentiel, passer
> `product-images` en privé avec URL signées.

## 6. Auth

- Supabase Auth gère identité, mots de passe, sessions, refresh tokens, reset password.
- Méthodes prévues : e-mail + mot de passe ; **téléphone + OTP SMS** recommandé pour le
  marché sénégalais (fournisseur SMS à configurer dans le Dashboard — documenté en Phase 3).
- Confirmation d'e-mail activée en production ; politique de mot de passe minimale (≥ 8).
- Les rôles métier ne sont **pas** stockés dans le JWT (ils changent ; la RLS lit
  `business_members` à chaque requête).
- Configuration Dashboard manuelle requise : URL de redirection, templates e-mail,
  fournisseur SMS, rate limits — listée dans le README au fil des phases.

## 7. Secrets

- `.env*` ignorés par Git ; `.env.example` sans valeurs réelles.
- Secrets Edge Functions : `supabase secrets set NAME=value` (jamais en dur).
- Webhooks : `billing-webhook` exige `x-jendpro-timestamp` + `x-jendpro-signature`
  = hex(HMAC-SHA256(`BILLING_WEBHOOK_SECRET`, `"{timestamp}.{corps brut}"`)), horodatage à
  ± 5 min (anti-rejeu), comparaison à temps constant ; idempotence par `(provider, event_id)`
  en base ; montant ≥ prix du plan × mois vérifié en base. Sans secret configuré, la fonction
  répond `NOT_CONFIGURED` (fail-closed).
- RPC `platform_*` : exécutables par `service_role` uniquement (révoquées pour `anon` et
  `authenticated`, vérifié en production).
- Logs des Edge Functions : identifiants uniquement, jamais de données personnelles ni de
  paiement.

Secrets à définir en production (jamais dans Git) :

```bash
npx supabase secrets set BILLING_WEBHOOK_SECRET=$(openssl rand -hex 32)
npx supabase secrets set SITE_URL=https://app.jendpro.sn   # redirection des e-mails d'invitation
```

## 8. Stratégie de tests de sécurité

Outil : **pgTAP** via `supabase test db` (fichiers `supabase/tests/database/`), avec impersonation :

```sql
set local role authenticated;
set local request.jwt.claims = '{"sub":"<user_uuid>","role":"authenticated"}';
```

Jeu de données de test : 2 entreprises (A, B), un utilisateur par rôle dans A, un OWNER
dans B, un utilisateur sans entreprise, un utilisateur membre de A **et** B.

Pour **chaque table** :
- SELECT/INSERT/UPDATE/DELETE cross-tenant → 0 ligne / erreur.
- Chaque rôle → autorisé/refusé selon la matrice.
- `anon` → aucun accès.
- Tentative de changer `business_id` d'une ligne → refus.
- Tentative de référencer une ressource d'un autre tenant via FK → refus.

Pour **chaque RPC** : appel avec `business_id` étranger, permission manquante,
ressource d'un autre tenant passée en paramètre, montants falsifiés, rejeu.

Un test transversal (`00100_foundation.test.sql`) vérifie à chaque exécution que **toutes**
les tables de `public` ont la RLS activée, que `anon` n'a **aucun** privilège sur les tables ni
les fonctions, et que toute fonction `SECURITY DEFINER` fixe son `search_path`.

Garde-fous permanents (`01700_hardening.test.sql`) : la liste des RPC exposées, la liste des
tables/colonnes modifiables par les clients et la liste des `SECURITY DEFINER` sans
`require_permission` sont figées ; toute modification fait échouer la CI jusqu'à revue.

Validation des tests par mutation (2026-10-07) : l'injection d'une policy permissive et d'un
droit `UPDATE (business_id)` fait échouer les suites d'isolation et de membres.
