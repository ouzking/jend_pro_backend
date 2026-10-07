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
