# Rôles et permissions (RBAC) — JËND PRO

> Statut : **matrice cible (Phase 1)**, implémentée en Phase 4 (seed dans la migration `rbac`).
> Le frontend peut lire les permissions de l'utilisateur pour adapter l'UI, mais
> **seule la base de données décide**.

## 1. Modèle

```text
business_members (user × business) ──► roles ──< role_permissions >── permissions
```

- Un membre a **un** rôle par entreprise ; un utilisateur peut avoir des rôles
  différents dans des entreprises différentes.
- Les **rôles système** (`business_id IS NULL`, `is_system = true`) sont partagés par
  toutes les entreprises et non modifiables par les clients.
- Des **rôles personnalisés** par entreprise (`business_id NOT NULL`) sont prévus par le
  schéma ; leur gestion UI n'est pas en V1.
- Ajouter une permission = migration qui insère dans `permissions` et `role_permissions`.
  Aucun changement de code client nécessaire.

Le client récupère ses permissions via la RPC `get_my_permissions(p_business_id)`.

| RPC | Permission | Effet |
|---|---|---|
| `create_business(name, phone?, city?, address?)` | utilisateur connecté | Crée l'entreprise, l'emplacement par défaut, le membre OWNER |
| `get_my_permissions(business_id)` | — | Codes de permission de l'appelant |
| `list_my_invitations()` | — | Invitations en attente de l'appelant |
| `list_business_members(business_id)` | membre actif (`members.read` pour les détails) | Annuaire |
| `invite_member(business_id, email, role_code)` | `members.manage` | Invite un utilisateur existant |
| `accept_invitation(business_id)` / `decline_invitation(business_id)` | invité | Rejoint / refuse |
| `change_member_role(business_id, user_id, role_code)` | `members.manage` | Change le rôle |
| `set_member_status(business_id, user_id, status)` | `members.manage` | Suspend (`SUSPENDED`) / réactive (`ACTIVE`) |
| `remove_member(business_id, user_id)` | `members.manage` | Retire un membre ou annule une invitation |
| `leave_business(business_id)` | membre | Quitte l'entreprise |
| `set_product_status(product_id, status)` | `products.delete` | Archive (`ARCHIVED`) / réactive (`ACTIVE`) un produit |
| `adjust_stock(business_id, product_id, location_id, type, quantity, reason?)` | `inventory.adjust` | Stock initial, ajustement, perte, casse |
| `count_stock(business_id, product_id, location_id, counted, reason?)` | `inventory.adjust` | Inventaire physique |
| `transfer_stock(business_id, product_id, from_id, to_id, quantity, reason?)` | `inventory.transfer` | Transfert entre emplacements |
| `list_low_stock(business_id, location_id?)` | `inventory.read` | Produits sous le seuil minimal |
| `set_customer_credit_limit(customer_id, limit)` | `customers.manage` | Plafond de crédit (`0` aucun, `NULL` illimité) |
| `record_customer_payment(customer_id, amount, method, location_id, external_reference?, note?)` | `customers.payments` | Règlement d'une dette client |
| `adjust_customer_balance(customer_id, amount, reason)` | `customers.manage` | Correction / reprise de dette |
| `save_purchase(business_id, purchase_id?, supplier_id?, location_id, items, discount?, supplier_reference?, notes?)` | `purchases.create` | Crée / modifie un achat (lignes remplacées) |
| `order_purchase(purchase_id)` | `purchases.create` | Passe l'achat en commandé |
| `receive_purchase(purchase_id)` | `purchases.receive` | Réception : stock + CMP |
| `cancel_purchase(purchase_id, reason)` | `purchases.cancel` | Annule avant réception |
| `record_purchase_payment(purchase_id, amount, method, location_id, external_reference?, note?)` | `purchases.payments` | Paiement fournisseur |
| `create_sale(business_id, client_reference, location_id, items, payments?, customer_id?, discount?, notes?)` | `sales.create` (+ `sales.discount`, `sales.credit`) | Vente atomique et idempotente |
| `cancel_sale(sale_id, reason, refund_method?)` | `sales.cancel` | Annulation totale avec remboursement |

Inviter une personne **sans compte** nécessite l'API admin d'Auth : ce sera une Edge Function
(Phase 14) qui créera le compte puis appellera `invite_member`.

## 2. Catalogue des permissions

| Module | Permission | Description |
|---|---|---|
| Entreprise | `settings.manage` | Modifier les informations et paramètres de l'entreprise, les emplacements |
| | `subscription.manage` | Voir/changer l'abonnement (déclenche le paiement côté serveur) |
| Membres | `members.read` | Voir la liste des membres et leurs rôles |
| | `members.manage` | Inviter, changer le rôle, suspendre, retirer un membre |
| Employés | `employees.read` | Voir les fiches employés |
| | `employees.manage` | Créer/modifier les fiches employés (salaires inclus) |
| Produits | `products.read` | Voir le catalogue |
| | `products.create` | Créer un produit |
| | `products.update` | Modifier un produit (prix, image…) |
| | `products.delete` | Archiver un produit |
| | `products.read_cost` | Voir les coûts d'achat et les marges |
| | `categories.manage` | Gérer les catégories |
| Stock | `inventory.read` | Voir les stocks et mouvements |
| | `inventory.adjust` | Ajustements, pertes, casse, stock initial |
| | `inventory.transfer` | Transferts entre emplacements |
| Clients | `customers.read` | Voir les clients, soldes et historiques |
| | `customers.create` | Créer un client (ex. au moment de la vente) |
| | `customers.manage` | Modifier/archiver un client, définir le plafond de crédit |
| | `customers.payments` | Enregistrer un règlement de crédit client |
| Fournisseurs | `suppliers.read` | Voir les fournisseurs |
| | `suppliers.manage` | Créer/modifier/archiver les fournisseurs |
| Achats | `purchases.read` | Voir les achats |
| | `purchases.create` | Créer/modifier un achat (brouillon, commande) |
| | `purchases.receive` | Réceptionner un achat (impacte le stock) |
| | `purchases.payments` | Enregistrer un paiement fournisseur |
| | `purchases.cancel` | Annuler un achat non réceptionné |
| Ventes | `sales.read` | Voir toutes les ventes |
| | `sales.read_own` | Voir uniquement ses propres ventes |
| | `sales.create` | Enregistrer une vente |
| | `sales.discount` | Appliquer une remise |
| | `sales.credit` | Vendre à crédit (tout ou partie) |
| | `sales.cancel` | Annuler une vente (remet en stock, inverse paiements/crédit) |
| Dépenses | `expenses.read` | Voir les dépenses |
| | `expenses.create` | Enregistrer une dépense |
| | `expenses.manage` | Modifier/supprimer une dépense, gérer les catégories |
| Rapports | `reports.read` | Tableaux de bord, CA, marges, statistiques |
| Audit | `audit.read` | Consulter le journal d'audit |

## 3. Matrice des rôles système

✅ = accordé · — = refusé

| Permission | OWNER | ADMIN | MANAGER | CASHIER | STOCK_MANAGER |
|---|:-:|:-:|:-:|:-:|:-:|
| `settings.manage` | ✅ | ✅ | — | — | — |
| `subscription.manage` | ✅ | — | — | — | — |
| `members.read` | ✅ | ✅ | ✅ | — | — |
| `members.manage` | ✅ | ✅ | — | — | — |
| `employees.read` | ✅ | ✅ | ✅ | — | — |
| `employees.manage` | ✅ | ✅ | — | — | — |
| `products.read` | ✅ | ✅ | ✅ | ✅ | ✅ |
| `products.create` | ✅ | ✅ | ✅ | — | ✅ |
| `products.update` | ✅ | ✅ | ✅ | — | ✅ |
| `products.delete` | ✅ | ✅ | ✅ | — | — |
| `products.read_cost` | ✅ | ✅ | ✅ | — | ✅ |
| `categories.manage` | ✅ | ✅ | ✅ | — | ✅ |
| `inventory.read` | ✅ | ✅ | ✅ | ✅ | ✅ |
| `inventory.adjust` | ✅ | ✅ | ✅ | — | ✅ |
| `inventory.transfer` | ✅ | ✅ | ✅ | — | ✅ |
| `customers.read` | ✅ | ✅ | ✅ | ✅ | — |
| `customers.create` | ✅ | ✅ | ✅ | ✅ | — |
| `customers.manage` | ✅ | ✅ | ✅ | — | — |
| `customers.payments` | ✅ | ✅ | ✅ | ✅ | — |
| `suppliers.read` | ✅ | ✅ | ✅ | — | ✅ |
| `suppliers.manage` | ✅ | ✅ | ✅ | — | ✅ |
| `purchases.read` | ✅ | ✅ | ✅ | — | ✅ |
| `purchases.create` | ✅ | ✅ | ✅ | — | ✅ |
| `purchases.receive` | ✅ | ✅ | ✅ | — | ✅ |
| `purchases.payments` | ✅ | ✅ | ✅ | — | — |
| `purchases.cancel` | ✅ | ✅ | ✅ | — | — |
| `sales.read` | ✅ | ✅ | ✅ | — | — |
| `sales.read_own` | ✅ | ✅ | ✅ | ✅ | — |
| `sales.create` | ✅ | ✅ | ✅ | ✅ | — |
| `sales.discount` | ✅ | ✅ | ✅ | — | — |
| `sales.credit` | ✅ | ✅ | ✅ | ✅ | — |
| `sales.cancel` | ✅ | ✅ | ✅ | — | — |
| `expenses.read` | ✅ | ✅ | ✅ | — | — |
| `expenses.create` | ✅ | ✅ | ✅ | — | — |
| `expenses.manage` | ✅ | ✅ | — | — | — |
| `reports.read` | ✅ | ✅ | ✅ | — | — |
| `audit.read` | ✅ | ✅ | — | — | — |

Le caissier peut vendre à crédit et encaisser les règlements (décision du 2026-10-07),
mais ne voit ni les coûts ni les marges. Le STOCK_MANAGER voit les coûts car il saisit
et réceptionne les achats.

## 4. Règles de gestion des membres

Règle générique (valable aussi pour les futurs rôles personnalisés) : **on ne peut attribuer,
modifier, suspendre ou retirer qu'un rôle dont toutes les permissions sont détenues par
l'appelant.** Les règles 2 et 3 en découlent (l'ADMIN n'a pas `subscription.manage`).

1. Une entreprise a **toujours au moins un OWNER actif** (trigger bloquant, même pour `service_role`).
2. Seul un OWNER peut attribuer ou retirer le rôle OWNER (transfert de propriété :
   promouvoir un autre OWNER, puis quitter ou se faire rétrograder).
3. Un ADMIN ne peut ni modifier, ni suspendre, ni retirer un OWNER.
4. Un membre ne peut pas modifier son propre rôle ni son propre statut.
5. Un membre peut quitter une entreprise, sauf s'il en est le dernier OWNER.
6. Toute modification de rôle ou de statut est auditée (`member.role_change`, `member.remove`…).
7. Les invitations (`status = INVITED`) n'ouvrent aucun droit avant acceptation.
8. Un membre `SUSPENDED` perd immédiatement tout accès (les helpers ne considèrent que `ACTIVE`).

## 5. Permissions et limites d'abonnement

Les permissions disent **qui** peut faire une action ; les **limites du plan** disent
**combien** (membres, produits, emplacements). Les deux sont vérifiées côté base, de
façon indépendante (voir [business-rules.md §9](business-rules.md#9-abonnements)).

En **mode restreint** (abonnement hors bonne situation), seules les permissions marquées
`allowed_when_restricted` restent effectives : toutes les lectures, `sales.create`,
`sales.credit`, `sales.discount`, `customers.create`, `customers.payments`,
`subscription.manage`. Le rôle du membre ne change pas : c'est l'ensemble effectif qui est
filtré, au même endroit que la vérification des rôles.

| RPC | Permission | Effet |
|---|---|---|
| `get_subscription_status(business_id)` | membre actif | Plan, statut, restreint ?, limites, utilisation |
| `get_audit_log(business_id, limit?, before?, before_id?, action?, resource_type?, resource_id?, actor_id?)` | `audit.read` | Journal d'audit paginé avec nom de l'acteur |
| `get_dashboard_summary(business_id, from, to, location_id?)` | `reports.read` (+ `products.read_cost` pour la marge) | Indicateurs de la période |
| `get_sales_timeseries(business_id, from, to, granularity?, location_id?)` | `reports.read` | Évolution jour / semaine / mois |
| `get_top_products(business_id, from, to, limit?, location_id?)` | `reports.read` | Meilleures ventes |

## 6. Back-office plateforme (Phase 16)

Le back-office est utilisé par **l'équipe JËND PRO**, pas par les commerçants. Il ne détient
jamais la clé `service_role` : le staff se connecte comme un utilisateur normal et est
autorisé par un **RBAC plateforme séparé** (`platform_admins` × `platform_role_permissions`),
sans aucun lien avec `business_members`.

- Toute lecture inter-entreprises passe par une RPC `admin_*` qui commence par
  `private.require_platform_permission('<permission>')`. **Aucune policy n'a été ajoutée aux
  tables des entreprises** : l'isolation des tenants est inchangée.
- Le premier `SUPER_ADMIN` est créé en SQL (éditeur SQL / `service_role`) :
  `insert into public.platform_admins (user_id, role) select id, 'SUPER_ADMIN' from auth.users where email = '…';`
- Un administrateur ne modifie ni son propre rôle ni son propre statut ; un admin suspendu
  perd immédiatement toutes ses permissions ; il reste toujours un `SUPER_ADMIN` actif.

| Permission | SUPER_ADMIN | OPERATIONS | SUPPORT | FINANCE | ANALYST |
|---|:-:|:-:|:-:|:-:|:-:|
| `businesses.read` | ✅ | ✅ | ✅ | ✅ | ✅ |
| `businesses.manage` (suspendre / réactiver) | ✅ | ✅ | — | — | — |
| `users.read` | ✅ | ✅ | ✅ | — | — |
| `subscriptions.read` | ✅ | ✅ | ✅ | ✅ | ✅ |
| `billing.read` | ✅ | ✅ | — | ✅ | ✅ |
| `billing.manage` (paiement hors ligne) | ✅ | — | — | ✅ | — |
| `support.read` | ✅ | ✅ | ✅ | — | — |
| `support.manage` | ✅ | ✅ | ✅ | — | — |
| `announcements.read` | ✅ | ✅ | ✅ | — | — |
| `announcements.manage` | ✅ | ✅ | — | — | — |
| `audit.read` (toute la plateforme) | ✅ | ✅ | — | ✅ | — |
| `analytics.read` | ✅ | ✅ | — | ✅ | ✅ |
| `admins.manage` | ✅ | — | — | — | — |

| RPC | Permission | Effet |
|---|---|---|
| `get_my_platform_access()` | — | Rôle, statut et permissions plateforme de l'appelant (0 ligne si non-staff) |
| `admin_list_businesses(search?, status?, plan_code?, subscription_status?, created_from?, created_to?, sort?, limit?, offset?)` | `businesses.read` | Liste paginée (+ `total_count`) |
| `admin_get_business(business_id)` | `businesses.read` | Fiche, compteurs, activité 30 j, historique d'abonnement |
| `admin_list_business_members(business_id)` | `businesses.read` | Membres avec e-mail et dernière connexion |
| `admin_set_business_status(business_id, status, reason)` | `businesses.manage` | Suspension / réactivation, auditée, propriétaires notifiés |
| `admin_list_users(search?, limit?, offset?)` / `admin_get_user(user_id)` | `users.read` | Utilisateurs et appartenances |
| `admin_list_subscriptions(status?, plan_code?, search?, ending_within_days?, current_only?, limit?, offset?)` | `subscriptions.read` | Abonnements |
| `admin_list_billing_events(search?, provider?, from?, to?, limit?, offset?)` | `billing.read` | Paiements d'abonnement **confirmés** |
| `admin_record_manual_payment(business_id, plan_code, months, amount, reference, note?)` | `billing.manage` | Paiement hors ligne : mêmes règles que le webhook (`provider = MANUAL`) |
| `admin_get_audit_log(limit?, before?, before_id?, business_id?, action?, resource_type?, actor_id?, from?, to?)` | `audit.read` | Journal de toute la plateforme (keyset) |
| `admin_get_overview(from, to)` / `admin_get_timeseries(from, to, granularity?)` | `analytics.read` | Indicateurs plateforme ([business-rules.md §14](business-rules.md#14-indicateurs-plateforme-back-office)) |
| `admin_list_support_tickets(…)` / `admin_get_support_ticket(id)` | `support.read` | Tickets et conversation (notes internes incluses) |
| `admin_reply_support_ticket(id, body, internal?)` / `admin_update_support_ticket(id, status?, priority?, assigned_to?, unassign?)` | `support.manage` | Réponse, note interne, statut, assignation |
| `admin_list_announcements(limit?, offset?)` / `admin_count_announcement_recipients(audience, value?)` | `announcements.read` | Historique, aperçu de l'audience |
| `admin_save_announcement(id?, title, body, audience, value?)` / `admin_delete_announcement(id)` / `admin_send_announcement(id)` | `announcements.manage` | Brouillon, suppression de brouillon, envoi |
| `admin_list_admins()` / `admin_grant_platform_role(email, role)` / `admin_set_admin_status(user_id, status)` | `admins.manage` | Équipe plateforme |
| `create_support_ticket(subject, body, business_id?, priority?)` / `reply_support_ticket(id, body)` | utilisateur connecté (membre actif si `business_id`) | Côté commerçant (app) |

### 6.1 Double authentification (Phase 17)

Règle appliquée en base, dans `private.has_platform_permission` (donc par toutes les RPC
`admin_*` **et** les policies du staff), à partir du niveau de session `aal` du JWT :

1. Un membre du staff qui a activé un facteur TOTP vérifié doit avoir une session **aal2**
   pour **toute** permission plateforme : un mot de passe volé ne donne plus rien.
2. Les permissions marquées `platform_permissions.requires_mfa` exigent **toujours** aal2 :
   `businesses.manage`, `billing.manage`, `admins.manage`, `announcements.manage`.

Erreurs : `PERMISSION_DENIED` (le rôle n'a pas la permission) ≠ `MFA_REQUIRED` (le rôle l'a,
mais la session doit être validée par un second facteur). `get_my_platform_access()` renvoie
aussi `mfa_permissions`, `mfa_enrolled` et `aal` pour que l'interface guide l'utilisateur.
TOTP : activé dans `config.toml` (local) ; activé par défaut sur les projets hébergés
(Dashboard → Authentication → Multi-Factor).
