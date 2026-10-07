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

Tous : `LANGUAGE sql|plpgsql STABLE SECURITY DEFINER SET search_path = ''`,
`REVOKE ALL … FROM public`, `GRANT EXECUTE … TO authenticated`.
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
- **profiles** : chacun lit/modifie son profil ; les membres d'une même entreprise voient
  le nom/avatar de leurs collègues (pas le téléphone sauf permission `members.read`).
- **businesses** : lecture si membre ; mise à jour si `settings.manage` ; création via RPC uniquement ; pas de DELETE client.
- **business_members** : lecture si membre (`members.read` pour la liste complète, sinon sa propre ligne) ; écriture via RPC `invite_member`, `change_member_role`, `remove_member`.
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
| `business-assets` | Lecture publique | `{business_id}/logo.*` | Tous (logos sur reçus) | `settings.manage` |
| `product-images` | Lecture publique | `{business_id}/{product_id}/*` | Tous (URL non devinable) | `products.update` |
| `documents` | **Privé** | `{business_id}/expenses/…`, `{business_id}/purchases/…` | Permission du module concerné | Idem |
| `invoices` | **Privé** | `{business_id}/{sale_id}.pdf` | `sales.read` | Edge Function (`service_role`) |

Policies sur `storage.objects` basées sur `(storage.foldername(name))[1]::uuid` →
`private.has_permission(...)`. Limites de taille et types MIME définis par bucket.
Fichiers privés servis par **URL signées** à durée courte.

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
- Webhooks (Wave, Orange Money) : vérification de signature obligatoire, idempotence par
  `external_reference`.

## 8. Stratégie de tests de sécurité

Outil : **pgTAP** via `supabase test db`, avec impersonation :

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

Un test transversal vérifie automatiquement que **toutes** les tables de `public` ont
la RLS activée et que `anon` n'a aucun privilège d'écriture.
