# Guide d'intégration frontend (Flutter / React) — JËND PRO

> Pour : développeurs Flutter et React qui consomment le backend Supabase.
> Mis à jour à chaque phase backend. État actuel : **Phases 1 à 8** (voir README pour la production).

## 1. Ce qui est prêt / ce qui arrive

| Domaine | État | Comment l'utiliser |
|---|---|---|
| Inscription, connexion, session, profil | ✅ Prêt | Supabase Auth + table `profiles` |
| Entreprises, emplacements, choix de l'entreprise active | ✅ Prêt | `businesses`, `locations`, RPC `create_business` |
| Membres, invitations, rôles, permissions | ✅ Prêt | RPC `invite_member`, `get_my_permissions`… |
| Catégories, produits, coûts, images produits, logo | ✅ Prêt | Tables `categories`, `products`, `product_costs` + Storage |
| Stock / inventaire | ✅ Prêt | Lecture `inventory`, `inventory_movements` ; RPC `adjust_stock`, `count_stock`, `transfer_stock`, `list_low_stock` |
| Clients et crédits | ✅ Prêt | Table `customers`, relevé `customer_transactions` ; RPC `record_customer_payment`, `set_customer_credit_limit`, `adjust_customer_balance` |
| Fournisseurs, achats | ✅ Prêt | Tables `suppliers`, `supplier_products` ; lecture `purchases`, `purchase_items`, vue `supplier_balances` ; RPC d'achat |
| **Ventes, paiements (caisse)** | ⏳ Phase 9 | Une RPC `create_sale` atomique sera fournie : ne rien calculer « en vrai » côté client |
| Dépenses, employés, abonnements, notifications | ⏳ Phases 10-12 | — |

Règle d'or : **le frontend n'est jamais une couche de sécurité ni la source de vérité des
calculs**. Il affiche, saisit et appelle l'API ; la base décide (RLS, RPC).

## 2. Connexion au backend

| Environnement | URL | Clé |
|---|---|---|
| Production `jend_pro` | `https://lmyhrksehcodyylzphyn.supabase.co` | Clé **publishable** (Dashboard → Project Settings → API Keys) |
| Local (`npx supabase start` dans le dépôt backend) | `http://127.0.0.1:54421` (émulateur Android : `http://10.0.2.2:54421`) | Clé publishable affichée par `npx supabase status` |

- **Jamais** la clé `service_role` / secret dans Flutter ou React.
- Comptes de démo **en local uniquement** (mot de passe `jendpro-demo`) :
  `owner@demo.jendpro.local` (OWNER), `cashier@demo.jendpro.local` (CASHIER),
  entreprise « Boutique Démo Dakar ».

```dart
// Flutter (supabase_flutter)
await Supabase.initialize(url: supabaseUrl, anonKey: publishableKey);
final supabase = Supabase.instance.client;
```

```ts
// React (@supabase/supabase-js) — types générés : types/database.types.ts du dépôt backend
import { createClient } from '@supabase/supabase-js';
import type { Database } from './database.types';
export const supabase = createClient<Database>(SUPABASE_URL, SUPABASE_PUBLISHABLE_KEY);
```

Régénérer les types après chaque phase : `npx supabase gen types typescript --linked --schema public`.

## 3. Authentification

```ts
// Inscription : full_name est copié dans profiles par le backend
await supabase.auth.signUp({ email, password, options: { data: { full_name: 'Awa Ndiaye' } } });
await supabase.auth.signInWithPassword({ email, password });
await supabase.auth.signOut();
await supabase.auth.resetPasswordForEmail(email, { redirectTo: 'https://<app>/reset' });
```

- Mot de passe : 8 caractères minimum.
- Le SDK gère le refresh token ; écouter `onAuthStateChange`.
- Profil : `select * from profiles` renvoie **uniquement** celui de l'utilisateur ;
  modifiable : `full_name`, `phone` (`+221771234567`), `avatar_path`, `locale` (`fr`|`en`|`wo`).

## 4. Parcours d'entrée (onboarding)

```text
connexion
  ├─ list_my_invitations()  → invitations en attente → accept_invitation / decline_invitation
  ├─ select businesses       → entreprises où l'utilisateur est membre ACTIF
  │     ├─ 0 → écran « Créer mon entreprise » → rpc('create_business', {p_name, p_phone, p_city, p_address})
  │     ├─ 1 → entrer directement
  │     └─ n → sélecteur d'entreprise
  └─ entreprise active choisie (stockée localement)
        └─ rpc('get_my_permissions', {p_business_id}) → adapter l'UI
```

- Un utilisateur peut appartenir à **plusieurs entreprises** avec des rôles différents.
- **Toutes** les requêtes métier doivent filtrer par l'entreprise active :
  `.eq('business_id', activeBusinessId)` (la RLS empêche de toute façon de voir les autres).
- Rafraîchir les permissions au retour au premier plan : un rôle peut changer ou un
  membre être suspendu à tout moment (accès coupé immédiatement côté serveur).

## 5. Permissions et UI

`get_my_permissions` renvoie une liste de codes (`products.create`, `sales.cancel`…).
Utilisez-la pour masquer/désactiver boutons et écrans. Catalogue complet et matrice :
[roles-and-permissions.md](roles-and-permissions.md).

Exemples : le caissier n'a pas `products.read_cost` → ne pas afficher les colonnes coût/marge
(la table `product_costs` lui renvoie de toute façon 0 ligne).

## 6. Catalogue

```ts
// Liste paginée
const { data } = await supabase.from('products')
  .select('id, name, sku, barcode, unit, sale_price, status, image_path, category:categories(id, name)')
  .eq('business_id', bid).eq('status', 'ACTIVE')
  .order('name').range(0, 49);

// Recherche par code-barres (scanner)
await supabase.from('products').select('*').eq('business_id', bid).eq('barcode', code).maybeSingle();

// Création (business_id obligatoire ; created_by, status sont gérés par le serveur)
const { data: p } = await supabase.from('products')
  .insert({ business_id: bid, name: 'Bissap 1L', sale_price: 1500, unit: 'bouteille', sku: 'BIS-1L' })
  .select().single();

// Coût (seulement si products.read_cost + products.update) — la ligne existe déjà
await supabase.from('product_costs').update({ cost_price: 900 }).eq('product_id', p.id);

// Archiver / réactiver (products.delete) — pas de DELETE sur products
await supabase.rpc('set_product_status', { p_product_id: p.id, p_status: 'ARCHIVED' });
```

Champs **non modifiables** après création : `business_id`, `track_stock`, `created_by`
(`status` via la RPC uniquement). Catégories : 2 niveaux maximum.

## 6 bis. Stock

```ts
// Stock d'un emplacement, avec le produit
await supabase.from('inventory')
  .select('quantity, product:products(id, name, unit, min_stock_level)')
  .eq('business_id', bid).eq('location_id', locationId);

// Historique d'un produit (pagination)
await supabase.from('inventory_movements')
  .select('type, quantity, quantity_after, reason, created_at, location_id')
  .eq('business_id', bid).eq('product_id', productId)
  .order('created_at', { ascending: false }).range(0, 49);

// Stock d'ouverture, perte (delta NÉGATIF), inventaire physique, transfert
await supabase.rpc('adjust_stock', { p_business_id: bid, p_product_id: pid, p_location_id: loc, p_type: 'INITIAL', p_quantity: 50 });
await supabase.rpc('adjust_stock', { p_business_id: bid, p_product_id: pid, p_location_id: loc, p_type: 'LOSS', p_quantity: -3, p_reason: 'Sac percé' });
await supabase.rpc('count_stock', { p_business_id: bid, p_product_id: pid, p_location_id: loc, p_counted_quantity: 42 });
await supabase.rpc('transfer_stock', { p_business_id: bid, p_product_id: pid, p_from_location_id: a, p_to_location_id: b, p_quantity: 10 });

// Alertes de stock faible (tableau de bord)
await supabase.rpc('list_low_stock', { p_business_id: bid });
```

- **Jamais** d'écriture directe dans `inventory` / `inventory_movements` (refusé).
- Inventaire physique : envoyer la quantité **comptée** via `count_stock`, pas un delta
  calculé côté client (le stock peut changer pendant le comptage).
- `INSUFFICIENT_STOCK` : `detail` contient `available` et `requested` (JSON) pour l'affichage.

## 6 ter. Clients et crédit

```ts
// Recherche client à la caisse
await supabase.from('customers').select('id, name, phone, balance, credit_limit')
  .eq('business_id', bid).eq('status', 'ACTIVE').ilike('name', `%${q}%`).limit(20);

// Création (caissier) : credit_limit / balance non fournis
await supabase.from('customers').insert({ business_id: bid, name: 'Fatou Sow', phone: '771234567' }).select().single();

// Débiteurs
await supabase.from('customers').select('id, name, phone, balance').eq('business_id', bid).gt('balance', 0).order('balance', { ascending: false });

// Relevé
await supabase.from('customer_transactions').select('type, amount, balance_after, note, created_at')
  .eq('business_id', bid).eq('customer_id', cid).order('created_at', { ascending: false }).range(0, 49);

// Règlement (Wave : passer l'id de transaction pour éviter les doublons)
await supabase.rpc('record_customer_payment', { p_customer_id: cid, p_amount: 10000, p_method: 'WAVE', p_location_id: loc, p_external_reference: 'TX-123' });
```

- `balance` = ce que le client **doit**. `credit_limit` : `0` = pas de crédit, `null` = illimité.
- Erreurs à traduire : `AMOUNT_EXCEEDS_BALANCE`, `CREDIT_LIMIT_EXCEEDED`, `CUSTOMER_HAS_BALANCE`.

## 6 quater. Achats

```ts
// Créer (purchase_id null) ou modifier un achat : les lignes sont remplacées en bloc
const { data: purchaseId } = await supabase.rpc('save_purchase', {
  p_business_id: bid, p_purchase_id: null, p_supplier_id: supplierId, p_location_id: loc,
  p_items: [{ product_id: riz, quantity: 25, unit_cost: 600 }, { product_id: huile, quantity: 12, unit_cost: 1200 }],
  p_discount_amount: 0, p_supplier_reference: 'FAC-2026-118',
});
await supabase.rpc('order_purchase', { p_purchase_id: purchaseId });        // facultatif
await supabase.rpc('receive_purchase', { p_purchase_id: purchaseId });      // stock + coût moyen
await supabase.rpc('record_purchase_payment', { p_purchase_id: purchaseId, p_amount: 20000, p_method: 'CASH', p_location_id: loc });

// Dettes fournisseurs
await supabase.from('supplier_balances').select('supplier_id, amount_due, advances_paid').eq('business_id', bid);
```

- Le serveur ignore tout total envoyé : il recalcule à partir des lignes.
- Réception partielle non gérée en V1 : créer un nouvel achat pour le reliquat.

## 7. Images (Storage)

| Bucket | Chemin obligatoire | Formats / taille | Qui écrit |
|---|---|---|---|
| `product-images` | `{business_id}/{product_id}/{uuid}.webp` | JPEG, PNG, WebP — 2 Mo | `products.update` |
| `business-assets` | `{business_id}/logo-{uuid}.webp` | JPEG, PNG, WebP — 1 Mo | `settings.manage` |

```ts
const path = `${bid}/${productId}/${crypto.randomUUID()}.webp`;
await supabase.storage.from('product-images').upload(path, file, { contentType: 'image/webp' });
await supabase.from('products').update({ image_path: path }).eq('id', productId);
const url = supabase.storage.from('product-images').getPublicUrl(path).data.publicUrl;
```

- Compresser/redimensionner côté client (WebP ~800 px) : réseau mobile.
- `image_path` / `logo_path` hors du dossier de l'entreprise sont refusés par la base.
- SVG refusé.

## 8. Argent et quantités

- Montants = **entiers en francs CFA** (`1500` = 1 500 FCFA). Pas de décimales, pas de float.
  Affichage : `NumberFormat('#,##0', 'fr')` + ` FCFA`.
- Quantités : décimales possibles (`numeric`, 3 décimales) seulement si
  `products.allows_fractional_quantity = true` ; sinon entiers.
- Les totaux de vente/achat seront **calculés par le serveur** (Phase 9) : le client peut
  afficher une estimation, mais la valeur de référence est celle renvoyée par la RPC.

## 9. Erreurs

Les erreurs métier renvoient `message` = code stable à traduire, `code` = SQLSTATE.
Table complète : [business-rules.md §13](business-rules.md#13-contrat-derreurs-des-rpc).

| Cas fréquent | `code` | `message` |
|---|---|---|
| Action non autorisée (RPC) | `42501` | `PERMISSION_DENIED` |
| Écriture refusée par RLS / colonne non modifiable | `42501` | `new row violates row-level security policy…` / `permission denied…` |
| SKU / code-barres déjà utilisé | `23505` | (unicité) |
| Valeur invalide (prix négatif, nom vide…) | `23514` | (CHECK) |
| Dernier propriétaire | `P0001` | `LAST_OWNER` |

Note : un `UPDATE` sur une ligne non autorisée ne lève pas d'erreur : il modifie 0 ligne.
Utiliser `.select()` après l'update pour vérifier le résultat.

## 10. Bonnes pratiques

- Pagination systématique (`range`) ; ne jamais charger un catalogue entier.
- Sélectionner les colonnes utiles plutôt que `*` sur les listes.
- Pas de clé `service_role`, pas de logique de stock/caisse côté client.
- Ventes hors ligne (Phase 9) : chaque vente portera un `client_reference` (UUID généré
  par l'app) pour être rejouée sans doublon — prévoir ce champ dans le modèle local.
