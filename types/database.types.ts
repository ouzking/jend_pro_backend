export type Json =
  | string
  | number
  | boolean
  | null
  | { [key: string]: Json | undefined }
  | Json[];

export type Database = {
  public: {
    Tables: {
      audit_logs: {
        Row: {
          action: string;
          actor_id: string | null;
          business_id: string | null;
          created_at: string;
          id: string;
          metadata: NonNullable<Json>;
          resource_id: string | null;
          resource_type: string;
        };
        ComputedFields: never;
        Insert: {
          action: string;
          actor_id?: string | null;
          business_id?: string | null;
          created_at?: string;
          id?: string;
          metadata?: NonNullable<Json>;
          resource_id?: string | null;
          resource_type: string;
        };
        Update: {
          action?: string;
          actor_id?: string | null;
          business_id?: string | null;
          created_at?: string;
          id?: string;
          metadata?: NonNullable<Json>;
          resource_id?: string | null;
          resource_type?: string;
        };
        Relationships: [
          {
            foreignKeyName: "audit_logs_business_id_fkey";
            columns: ["business_id"];
            isOneToOne: false;
            referencedRelation: "businesses";
            referencedColumns: ["id"];
          },
        ];
      };
      business_members: {
        Row: {
          business_id: string;
          created_at: string;
          id: string;
          invited_by: string | null;
          joined_at: string | null;
          role_id: string;
          status: Database["public"]["Enums"]["member_status"];
          updated_at: string;
          user_id: string;
        };
        ComputedFields: never;
        Insert: {
          business_id: string;
          created_at?: string;
          id?: string;
          invited_by?: string | null;
          joined_at?: string | null;
          role_id: string;
          status?: Database["public"]["Enums"]["member_status"];
          updated_at?: string;
          user_id: string;
        };
        Update: {
          business_id?: string;
          created_at?: string;
          id?: string;
          invited_by?: string | null;
          joined_at?: string | null;
          role_id?: string;
          status?: Database["public"]["Enums"]["member_status"];
          updated_at?: string;
          user_id?: string;
        };
        Relationships: [
          {
            foreignKeyName: "business_members_business_id_fkey";
            columns: ["business_id"];
            isOneToOne: false;
            referencedRelation: "businesses";
            referencedColumns: ["id"];
          },
          {
            foreignKeyName: "business_members_role_id_fkey";
            columns: ["role_id"];
            isOneToOne: false;
            referencedRelation: "roles";
            referencedColumns: ["id"];
          },
        ];
      };
      businesses: {
        Row: {
          address: string | null;
          allow_negative_stock: boolean;
          city: string | null;
          country_code: string;
          created_at: string;
          created_by: string | null;
          currency_code: string;
          email: string | null;
          id: string;
          legal_name: string | null;
          logo_path: string | null;
          name: string;
          ninea: string | null;
          phone: string | null;
          rccm: string | null;
          status: Database["public"]["Enums"]["business_status"];
          timezone: string;
          updated_at: string;
        };
        ComputedFields: never;
        Insert: {
          address?: string | null;
          allow_negative_stock?: boolean;
          city?: string | null;
          country_code?: string;
          created_at?: string;
          created_by?: string | null;
          currency_code?: string;
          email?: string | null;
          id?: string;
          legal_name?: string | null;
          logo_path?: string | null;
          name: string;
          ninea?: string | null;
          phone?: string | null;
          rccm?: string | null;
          status?: Database["public"]["Enums"]["business_status"];
          timezone?: string;
          updated_at?: string;
        };
        Update: {
          address?: string | null;
          allow_negative_stock?: boolean;
          city?: string | null;
          country_code?: string;
          created_at?: string;
          created_by?: string | null;
          currency_code?: string;
          email?: string | null;
          id?: string;
          legal_name?: string | null;
          logo_path?: string | null;
          name?: string;
          ninea?: string | null;
          phone?: string | null;
          rccm?: string | null;
          status?: Database["public"]["Enums"]["business_status"];
          timezone?: string;
          updated_at?: string;
        };
        Relationships: [];
      };
      categories: {
        Row: {
          business_id: string;
          created_at: string;
          id: string;
          name: string;
          parent_id: string | null;
          status: Database["public"]["Enums"]["record_status"];
          updated_at: string;
        };
        ComputedFields: never;
        Insert: {
          business_id: string;
          created_at?: string;
          id?: string;
          name: string;
          parent_id?: string | null;
          status?: Database["public"]["Enums"]["record_status"];
          updated_at?: string;
        };
        Update: {
          business_id?: string;
          created_at?: string;
          id?: string;
          name?: string;
          parent_id?: string | null;
          status?: Database["public"]["Enums"]["record_status"];
          updated_at?: string;
        };
        Relationships: [
          {
            foreignKeyName: "categories_business_id_fkey";
            columns: ["business_id"];
            isOneToOne: false;
            referencedRelation: "businesses";
            referencedColumns: ["id"];
          },
          {
            foreignKeyName: "categories_parent_fkey";
            columns: ["business_id", "parent_id"];
            isOneToOne: false;
            referencedRelation: "categories";
            referencedColumns: ["business_id", "id"];
          },
        ];
      };
      customer_transactions: {
        Row: {
          amount: number;
          balance_after: number;
          business_id: string;
          created_at: string;
          created_by: string | null;
          customer_id: string;
          id: string;
          note: string | null;
          payment_id: string | null;
          sale_id: string | null;
          type: Database["public"]["Enums"]["customer_transaction_type"];
        };
        ComputedFields: never;
        Insert: {
          amount: number;
          balance_after: number;
          business_id: string;
          created_at?: string;
          created_by?: string | null;
          customer_id: string;
          id?: string;
          note?: string | null;
          payment_id?: string | null;
          sale_id?: string | null;
          type: Database["public"]["Enums"]["customer_transaction_type"];
        };
        Update: {
          amount?: number;
          balance_after?: number;
          business_id?: string;
          created_at?: string;
          created_by?: string | null;
          customer_id?: string;
          id?: string;
          note?: string | null;
          payment_id?: string | null;
          sale_id?: string | null;
          type?: Database["public"]["Enums"]["customer_transaction_type"];
        };
        Relationships: [
          {
            foreignKeyName: "customer_transactions_customer_fkey";
            columns: ["business_id", "customer_id"];
            isOneToOne: false;
            referencedRelation: "customers";
            referencedColumns: ["business_id", "id"];
          },
          {
            foreignKeyName: "customer_transactions_payment_fkey";
            columns: ["business_id", "payment_id"];
            isOneToOne: false;
            referencedRelation: "payments";
            referencedColumns: ["business_id", "id"];
          },
          {
            foreignKeyName: "customer_transactions_sale_fkey";
            columns: ["business_id", "sale_id"];
            isOneToOne: false;
            referencedRelation: "sales";
            referencedColumns: ["business_id", "id"];
          },
        ];
      };
      customers: {
        Row: {
          address: string | null;
          balance: number;
          business_id: string;
          created_at: string;
          created_by: string | null;
          credit_limit: number | null;
          email: string | null;
          id: string;
          name: string;
          notes: string | null;
          phone: string | null;
          status: Database["public"]["Enums"]["record_status"];
          updated_at: string;
        };
        ComputedFields: never;
        Insert: {
          address?: string | null;
          balance?: number;
          business_id: string;
          created_at?: string;
          created_by?: string | null;
          credit_limit?: number | null;
          email?: string | null;
          id?: string;
          name: string;
          notes?: string | null;
          phone?: string | null;
          status?: Database["public"]["Enums"]["record_status"];
          updated_at?: string;
        };
        Update: {
          address?: string | null;
          balance?: number;
          business_id?: string;
          created_at?: string;
          created_by?: string | null;
          credit_limit?: number | null;
          email?: string | null;
          id?: string;
          name?: string;
          notes?: string | null;
          phone?: string | null;
          status?: Database["public"]["Enums"]["record_status"];
          updated_at?: string;
        };
        Relationships: [
          {
            foreignKeyName: "customers_business_id_fkey";
            columns: ["business_id"];
            isOneToOne: false;
            referencedRelation: "businesses";
            referencedColumns: ["id"];
          },
        ];
      };
      document_sequences: {
        Row: {
          business_id: string;
          doc_type: string;
          next_value: number;
          prefix: string;
        };
        ComputedFields: never;
        Insert: {
          business_id: string;
          doc_type: string;
          next_value?: number;
          prefix: string;
        };
        Update: {
          business_id?: string;
          doc_type?: string;
          next_value?: number;
          prefix?: string;
        };
        Relationships: [
          {
            foreignKeyName: "document_sequences_business_id_fkey";
            columns: ["business_id"];
            isOneToOne: false;
            referencedRelation: "businesses";
            referencedColumns: ["id"];
          },
        ];
      };
      inventory: {
        Row: {
          business_id: string;
          location_id: string;
          product_id: string;
          quantity: number;
          updated_at: string;
        };
        ComputedFields: never;
        Insert: {
          business_id: string;
          location_id: string;
          product_id: string;
          quantity?: number;
          updated_at?: string;
        };
        Update: {
          business_id?: string;
          location_id?: string;
          product_id?: string;
          quantity?: number;
          updated_at?: string;
        };
        Relationships: [
          {
            foreignKeyName: "inventory_location_fkey";
            columns: ["business_id", "location_id"];
            isOneToOne: false;
            referencedRelation: "locations";
            referencedColumns: ["business_id", "id"];
          },
          {
            foreignKeyName: "inventory_product_fkey";
            columns: ["business_id", "product_id"];
            isOneToOne: false;
            referencedRelation: "products";
            referencedColumns: ["business_id", "id"];
          },
        ];
      };
      inventory_movements: {
        Row: {
          business_id: string;
          created_at: string;
          created_by: string | null;
          id: string;
          location_id: string;
          product_id: string;
          quantity: number;
          quantity_after: number;
          reason: string | null;
          reference_id: string | null;
          reference_type: string | null;
          transfer_id: string | null;
          type: Database["public"]["Enums"]["inventory_movement_type"];
          unit_cost: number | null;
        };
        ComputedFields: never;
        Insert: {
          business_id: string;
          created_at?: string;
          created_by?: string | null;
          id?: string;
          location_id: string;
          product_id: string;
          quantity: number;
          quantity_after: number;
          reason?: string | null;
          reference_id?: string | null;
          reference_type?: string | null;
          transfer_id?: string | null;
          type: Database["public"]["Enums"]["inventory_movement_type"];
          unit_cost?: number | null;
        };
        Update: {
          business_id?: string;
          created_at?: string;
          created_by?: string | null;
          id?: string;
          location_id?: string;
          product_id?: string;
          quantity?: number;
          quantity_after?: number;
          reason?: string | null;
          reference_id?: string | null;
          reference_type?: string | null;
          transfer_id?: string | null;
          type?: Database["public"]["Enums"]["inventory_movement_type"];
          unit_cost?: number | null;
        };
        Relationships: [
          {
            foreignKeyName: "inventory_movements_location_fkey";
            columns: ["business_id", "location_id"];
            isOneToOne: false;
            referencedRelation: "locations";
            referencedColumns: ["business_id", "id"];
          },
          {
            foreignKeyName: "inventory_movements_product_fkey";
            columns: ["business_id", "product_id"];
            isOneToOne: false;
            referencedRelation: "products";
            referencedColumns: ["business_id", "id"];
          },
        ];
      };
      locations: {
        Row: {
          address: string | null;
          business_id: string;
          created_at: string;
          id: string;
          is_default: boolean;
          name: string;
          status: Database["public"]["Enums"]["record_status"];
          type: Database["public"]["Enums"]["location_type"];
          updated_at: string;
        };
        ComputedFields: never;
        Insert: {
          address?: string | null;
          business_id: string;
          created_at?: string;
          id?: string;
          is_default?: boolean;
          name: string;
          status?: Database["public"]["Enums"]["record_status"];
          type?: Database["public"]["Enums"]["location_type"];
          updated_at?: string;
        };
        Update: {
          address?: string | null;
          business_id?: string;
          created_at?: string;
          id?: string;
          is_default?: boolean;
          name?: string;
          status?: Database["public"]["Enums"]["record_status"];
          type?: Database["public"]["Enums"]["location_type"];
          updated_at?: string;
        };
        Relationships: [
          {
            foreignKeyName: "locations_business_id_fkey";
            columns: ["business_id"];
            isOneToOne: false;
            referencedRelation: "businesses";
            referencedColumns: ["id"];
          },
        ];
      };
      payments: {
        Row: {
          amount: number;
          business_id: string;
          created_at: string;
          customer_id: string | null;
          direction: Database["public"]["Enums"]["payment_direction"];
          external_reference: string | null;
          id: string;
          location_id: string;
          method: Database["public"]["Enums"]["payment_method"];
          note: string | null;
          paid_at: string;
          purchase_id: string | null;
          recorded_by: string | null;
          sale_id: string | null;
        };
        ComputedFields: never;
        Insert: {
          amount: number;
          business_id: string;
          created_at?: string;
          customer_id?: string | null;
          direction: Database["public"]["Enums"]["payment_direction"];
          external_reference?: string | null;
          id?: string;
          location_id: string;
          method: Database["public"]["Enums"]["payment_method"];
          note?: string | null;
          paid_at?: string;
          purchase_id?: string | null;
          recorded_by?: string | null;
          sale_id?: string | null;
        };
        Update: {
          amount?: number;
          business_id?: string;
          created_at?: string;
          customer_id?: string | null;
          direction?: Database["public"]["Enums"]["payment_direction"];
          external_reference?: string | null;
          id?: string;
          location_id?: string;
          method?: Database["public"]["Enums"]["payment_method"];
          note?: string | null;
          paid_at?: string;
          purchase_id?: string | null;
          recorded_by?: string | null;
          sale_id?: string | null;
        };
        Relationships: [
          {
            foreignKeyName: "payments_business_id_fkey";
            columns: ["business_id"];
            isOneToOne: false;
            referencedRelation: "businesses";
            referencedColumns: ["id"];
          },
          {
            foreignKeyName: "payments_customer_fkey";
            columns: ["business_id", "customer_id"];
            isOneToOne: false;
            referencedRelation: "customers";
            referencedColumns: ["business_id", "id"];
          },
          {
            foreignKeyName: "payments_location_fkey";
            columns: ["business_id", "location_id"];
            isOneToOne: false;
            referencedRelation: "locations";
            referencedColumns: ["business_id", "id"];
          },
          {
            foreignKeyName: "payments_purchase_fkey";
            columns: ["business_id", "purchase_id"];
            isOneToOne: false;
            referencedRelation: "purchases";
            referencedColumns: ["business_id", "id"];
          },
          {
            foreignKeyName: "payments_sale_fkey";
            columns: ["business_id", "sale_id"];
            isOneToOne: false;
            referencedRelation: "sales";
            referencedColumns: ["business_id", "id"];
          },
        ];
      };
      permissions: {
        Row: {
          code: string;
          created_at: string;
          description: string;
          module: string;
        };
        ComputedFields: never;
        Insert: {
          code: string;
          created_at?: string;
          description: string;
          module: string;
        };
        Update: {
          code?: string;
          created_at?: string;
          description?: string;
          module?: string;
        };
        Relationships: [];
      };
      product_costs: {
        Row: {
          business_id: string;
          cost_price: number;
          created_at: string;
          product_id: string;
          updated_at: string;
        };
        ComputedFields: never;
        Insert: {
          business_id: string;
          cost_price?: number;
          created_at?: string;
          product_id: string;
          updated_at?: string;
        };
        Update: {
          business_id?: string;
          cost_price?: number;
          created_at?: string;
          product_id?: string;
          updated_at?: string;
        };
        Relationships: [
          {
            foreignKeyName: "product_costs_product_fkey";
            columns: ["business_id", "product_id"];
            isOneToOne: false;
            referencedRelation: "products";
            referencedColumns: ["business_id", "id"];
          },
        ];
      };
      products: {
        Row: {
          allows_fractional_quantity: boolean;
          barcode: string | null;
          business_id: string;
          category_id: string | null;
          created_at: string;
          created_by: string | null;
          description: string | null;
          id: string;
          image_path: string | null;
          min_stock_level: number;
          name: string;
          sale_price: number;
          sku: string | null;
          status: Database["public"]["Enums"]["record_status"];
          track_stock: boolean;
          unit: string;
          updated_at: string;
        };
        ComputedFields: never;
        Insert: {
          allows_fractional_quantity?: boolean;
          barcode?: string | null;
          business_id: string;
          category_id?: string | null;
          created_at?: string;
          created_by?: string | null;
          description?: string | null;
          id?: string;
          image_path?: string | null;
          min_stock_level?: number;
          name: string;
          sale_price?: number;
          sku?: string | null;
          status?: Database["public"]["Enums"]["record_status"];
          track_stock?: boolean;
          unit?: string;
          updated_at?: string;
        };
        Update: {
          allows_fractional_quantity?: boolean;
          barcode?: string | null;
          business_id?: string;
          category_id?: string | null;
          created_at?: string;
          created_by?: string | null;
          description?: string | null;
          id?: string;
          image_path?: string | null;
          min_stock_level?: number;
          name?: string;
          sale_price?: number;
          sku?: string | null;
          status?: Database["public"]["Enums"]["record_status"];
          track_stock?: boolean;
          unit?: string;
          updated_at?: string;
        };
        Relationships: [
          {
            foreignKeyName: "products_business_id_fkey";
            columns: ["business_id"];
            isOneToOne: false;
            referencedRelation: "businesses";
            referencedColumns: ["id"];
          },
          {
            foreignKeyName: "products_category_fkey";
            columns: ["business_id", "category_id"];
            isOneToOne: false;
            referencedRelation: "categories";
            referencedColumns: ["business_id", "id"];
          },
        ];
      };
      profiles: {
        Row: {
          avatar_path: string | null;
          created_at: string;
          full_name: string | null;
          id: string;
          locale: string;
          phone: string | null;
          updated_at: string;
        };
        ComputedFields: never;
        Insert: {
          avatar_path?: string | null;
          created_at?: string;
          full_name?: string | null;
          id: string;
          locale?: string;
          phone?: string | null;
          updated_at?: string;
        };
        Update: {
          avatar_path?: string | null;
          created_at?: string;
          full_name?: string | null;
          id?: string;
          locale?: string;
          phone?: string | null;
          updated_at?: string;
        };
        Relationships: [];
      };
      purchase_items: {
        Row: {
          business_id: string;
          created_at: string;
          id: string;
          line_total: number;
          product_id: string;
          purchase_id: string;
          quantity: number;
          unit_cost: number;
        };
        ComputedFields: never;
        Insert: {
          business_id: string;
          created_at?: string;
          id?: string;
          line_total: number;
          product_id: string;
          purchase_id: string;
          quantity: number;
          unit_cost: number;
        };
        Update: {
          business_id?: string;
          created_at?: string;
          id?: string;
          line_total?: number;
          product_id?: string;
          purchase_id?: string;
          quantity?: number;
          unit_cost?: number;
        };
        Relationships: [
          {
            foreignKeyName: "purchase_items_product_fkey";
            columns: ["business_id", "product_id"];
            isOneToOne: false;
            referencedRelation: "products";
            referencedColumns: ["business_id", "id"];
          },
          {
            foreignKeyName: "purchase_items_purchase_fkey";
            columns: ["business_id", "purchase_id"];
            isOneToOne: false;
            referencedRelation: "purchases";
            referencedColumns: ["business_id", "id"];
          },
        ];
      };
      purchases: {
        Row: {
          amount_paid: number;
          business_id: string;
          cancel_reason: string | null;
          cancelled_at: string | null;
          cancelled_by: string | null;
          created_at: string;
          created_by: string | null;
          discount_amount: number;
          id: string;
          location_id: string;
          notes: string | null;
          number: string;
          ordered_at: string | null;
          payment_status: Database["public"]["Enums"]["payment_status"] | null;
          received_at: string | null;
          received_by: string | null;
          status: Database["public"]["Enums"]["purchase_status"];
          subtotal_amount: number;
          supplier_id: string | null;
          supplier_reference: string | null;
          total_amount: number;
          updated_at: string;
        };
        ComputedFields: never;
        Insert: {
          amount_paid?: number;
          business_id: string;
          cancel_reason?: string | null;
          cancelled_at?: string | null;
          cancelled_by?: string | null;
          created_at?: string;
          created_by?: string | null;
          discount_amount?: number;
          id?: string;
          location_id: string;
          notes?: string | null;
          number: string;
          ordered_at?: string | null;
          payment_status?: never;
          received_at?: string | null;
          received_by?: string | null;
          status?: Database["public"]["Enums"]["purchase_status"];
          subtotal_amount?: number;
          supplier_id?: string | null;
          supplier_reference?: string | null;
          total_amount?: number;
          updated_at?: string;
        };
        Update: {
          amount_paid?: number;
          business_id?: string;
          cancel_reason?: string | null;
          cancelled_at?: string | null;
          cancelled_by?: string | null;
          created_at?: string;
          created_by?: string | null;
          discount_amount?: number;
          id?: string;
          location_id?: string;
          notes?: string | null;
          number?: string;
          ordered_at?: string | null;
          payment_status?: never;
          received_at?: string | null;
          received_by?: string | null;
          status?: Database["public"]["Enums"]["purchase_status"];
          subtotal_amount?: number;
          supplier_id?: string | null;
          supplier_reference?: string | null;
          total_amount?: number;
          updated_at?: string;
        };
        Relationships: [
          {
            foreignKeyName: "purchases_business_id_fkey";
            columns: ["business_id"];
            isOneToOne: false;
            referencedRelation: "businesses";
            referencedColumns: ["id"];
          },
          {
            foreignKeyName: "purchases_location_fkey";
            columns: ["business_id", "location_id"];
            isOneToOne: false;
            referencedRelation: "locations";
            referencedColumns: ["business_id", "id"];
          },
          {
            foreignKeyName: "purchases_supplier_fkey";
            columns: ["business_id", "supplier_id"];
            isOneToOne: false;
            referencedRelation: "suppliers";
            referencedColumns: ["business_id", "id"];
          },
        ];
      };
      role_permissions: {
        Row: {
          created_at: string;
          permission_code: string;
          role_id: string;
        };
        ComputedFields: never;
        Insert: {
          created_at?: string;
          permission_code: string;
          role_id: string;
        };
        Update: {
          created_at?: string;
          permission_code?: string;
          role_id?: string;
        };
        Relationships: [
          {
            foreignKeyName: "role_permissions_permission_code_fkey";
            columns: ["permission_code"];
            isOneToOne: false;
            referencedRelation: "permissions";
            referencedColumns: ["code"];
          },
          {
            foreignKeyName: "role_permissions_role_id_fkey";
            columns: ["role_id"];
            isOneToOne: false;
            referencedRelation: "roles";
            referencedColumns: ["id"];
          },
        ];
      };
      roles: {
        Row: {
          business_id: string | null;
          code: string;
          created_at: string;
          description: string | null;
          id: string;
          is_system: boolean;
          name: string;
          updated_at: string;
        };
        ComputedFields: never;
        Insert: {
          business_id?: string | null;
          code: string;
          created_at?: string;
          description?: string | null;
          id?: string;
          is_system?: boolean;
          name: string;
          updated_at?: string;
        };
        Update: {
          business_id?: string | null;
          code?: string;
          created_at?: string;
          description?: string | null;
          id?: string;
          is_system?: boolean;
          name?: string;
          updated_at?: string;
        };
        Relationships: [
          {
            foreignKeyName: "roles_business_id_fkey";
            columns: ["business_id"];
            isOneToOne: false;
            referencedRelation: "businesses";
            referencedColumns: ["id"];
          },
        ];
      };
      sale_item_costs: {
        Row: {
          business_id: string;
          sale_item_id: string;
          unit_cost: number;
        };
        ComputedFields: never;
        Insert: {
          business_id: string;
          sale_item_id: string;
          unit_cost: number;
        };
        Update: {
          business_id?: string;
          sale_item_id?: string;
          unit_cost?: number;
        };
        Relationships: [
          {
            foreignKeyName: "sale_item_costs_item_fkey";
            columns: ["business_id", "sale_item_id"];
            isOneToOne: false;
            referencedRelation: "sale_items";
            referencedColumns: ["business_id", "id"];
          },
        ];
      };
      sale_items: {
        Row: {
          business_id: string;
          created_at: string;
          discount_amount: number;
          id: string;
          line_total: number;
          product_id: string;
          product_name: string;
          quantity: number;
          sale_id: string;
          unit_price: number;
        };
        ComputedFields: never;
        Insert: {
          business_id: string;
          created_at?: string;
          discount_amount?: number;
          id?: string;
          line_total: number;
          product_id: string;
          product_name: string;
          quantity: number;
          sale_id: string;
          unit_price: number;
        };
        Update: {
          business_id?: string;
          created_at?: string;
          discount_amount?: number;
          id?: string;
          line_total?: number;
          product_id?: string;
          product_name?: string;
          quantity?: number;
          sale_id?: string;
          unit_price?: number;
        };
        Relationships: [
          {
            foreignKeyName: "sale_items_product_fkey";
            columns: ["business_id", "product_id"];
            isOneToOne: false;
            referencedRelation: "products";
            referencedColumns: ["business_id", "id"];
          },
          {
            foreignKeyName: "sale_items_sale_fkey";
            columns: ["business_id", "sale_id"];
            isOneToOne: false;
            referencedRelation: "sales";
            referencedColumns: ["business_id", "id"];
          },
        ];
      };
      sales: {
        Row: {
          amount_paid: number;
          business_id: string;
          cancel_reason: string | null;
          cancelled_at: string | null;
          cancelled_by: string | null;
          client_reference: string;
          created_at: string;
          credit_amount: number;
          customer_id: string | null;
          discount_amount: number;
          id: string;
          location_id: string;
          notes: string | null;
          number: string;
          payment_status: Database["public"]["Enums"]["payment_status"] | null;
          sold_at: string;
          sold_by: string | null;
          status: Database["public"]["Enums"]["sale_status"];
          subtotal_amount: number;
          total_amount: number;
          updated_at: string;
        };
        ComputedFields: never;
        Insert: {
          amount_paid?: number;
          business_id: string;
          cancel_reason?: string | null;
          cancelled_at?: string | null;
          cancelled_by?: string | null;
          client_reference: string;
          created_at?: string;
          credit_amount?: number;
          customer_id?: string | null;
          discount_amount?: number;
          id?: string;
          location_id: string;
          notes?: string | null;
          number: string;
          payment_status?: never;
          sold_at?: string;
          sold_by?: string | null;
          status?: Database["public"]["Enums"]["sale_status"];
          subtotal_amount: number;
          total_amount: number;
          updated_at?: string;
        };
        Update: {
          amount_paid?: number;
          business_id?: string;
          cancel_reason?: string | null;
          cancelled_at?: string | null;
          cancelled_by?: string | null;
          client_reference?: string;
          created_at?: string;
          credit_amount?: number;
          customer_id?: string | null;
          discount_amount?: number;
          id?: string;
          location_id?: string;
          notes?: string | null;
          number?: string;
          payment_status?: never;
          sold_at?: string;
          sold_by?: string | null;
          status?: Database["public"]["Enums"]["sale_status"];
          subtotal_amount?: number;
          total_amount?: number;
          updated_at?: string;
        };
        Relationships: [
          {
            foreignKeyName: "sales_business_id_fkey";
            columns: ["business_id"];
            isOneToOne: false;
            referencedRelation: "businesses";
            referencedColumns: ["id"];
          },
          {
            foreignKeyName: "sales_customer_fkey";
            columns: ["business_id", "customer_id"];
            isOneToOne: false;
            referencedRelation: "customers";
            referencedColumns: ["business_id", "id"];
          },
          {
            foreignKeyName: "sales_location_fkey";
            columns: ["business_id", "location_id"];
            isOneToOne: false;
            referencedRelation: "locations";
            referencedColumns: ["business_id", "id"];
          },
        ];
      };
      supplier_products: {
        Row: {
          business_id: string;
          created_at: string;
          last_cost: number | null;
          product_id: string;
          supplier_id: string;
          supplier_sku: string | null;
          updated_at: string;
        };
        ComputedFields: never;
        Insert: {
          business_id: string;
          created_at?: string;
          last_cost?: number | null;
          product_id: string;
          supplier_id: string;
          supplier_sku?: string | null;
          updated_at?: string;
        };
        Update: {
          business_id?: string;
          created_at?: string;
          last_cost?: number | null;
          product_id?: string;
          supplier_id?: string;
          supplier_sku?: string | null;
          updated_at?: string;
        };
        Relationships: [
          {
            foreignKeyName: "supplier_products_product_fkey";
            columns: ["business_id", "product_id"];
            isOneToOne: false;
            referencedRelation: "products";
            referencedColumns: ["business_id", "id"];
          },
          {
            foreignKeyName: "supplier_products_supplier_fkey";
            columns: ["business_id", "supplier_id"];
            isOneToOne: false;
            referencedRelation: "suppliers";
            referencedColumns: ["business_id", "id"];
          },
        ];
      };
      suppliers: {
        Row: {
          address: string | null;
          business_id: string;
          contact_name: string | null;
          created_at: string;
          created_by: string | null;
          email: string | null;
          id: string;
          name: string;
          notes: string | null;
          phone: string | null;
          status: Database["public"]["Enums"]["record_status"];
          updated_at: string;
        };
        ComputedFields: never;
        Insert: {
          address?: string | null;
          business_id: string;
          contact_name?: string | null;
          created_at?: string;
          created_by?: string | null;
          email?: string | null;
          id?: string;
          name: string;
          notes?: string | null;
          phone?: string | null;
          status?: Database["public"]["Enums"]["record_status"];
          updated_at?: string;
        };
        Update: {
          address?: string | null;
          business_id?: string;
          contact_name?: string | null;
          created_at?: string;
          created_by?: string | null;
          email?: string | null;
          id?: string;
          name?: string;
          notes?: string | null;
          phone?: string | null;
          status?: Database["public"]["Enums"]["record_status"];
          updated_at?: string;
        };
        Relationships: [
          {
            foreignKeyName: "suppliers_business_id_fkey";
            columns: ["business_id"];
            isOneToOne: false;
            referencedRelation: "businesses";
            referencedColumns: ["id"];
          },
        ];
      };
    };
    Views: {
      supplier_balances: {
        Row: {
          advances_paid: number | null;
          amount_due: number | null;
          business_id: string | null;
          supplier_id: string | null;
          unpaid_purchases: number | null;
        };
        ComputedFields: never;
        Relationships: [
          {
            foreignKeyName: "purchases_business_id_fkey";
            columns: ["business_id"];
            isOneToOne: false;
            referencedRelation: "businesses";
            referencedColumns: ["id"];
          },
          {
            foreignKeyName: "purchases_supplier_fkey";
            columns: ["business_id", "supplier_id"];
            isOneToOne: false;
            referencedRelation: "suppliers";
            referencedColumns: ["business_id", "id"];
          },
        ];
      };
    };
    Functions: {
      accept_invitation: {
        Args: { p_business_id: string };
        Returns: undefined;
      };
      adjust_customer_balance: {
        Args: { p_amount: number; p_customer_id: string; p_reason: string };
        Returns: string;
      };
      adjust_stock: {
        Args: {
          p_business_id: string;
          p_location_id: string;
          p_product_id: string;
          p_quantity: number;
          p_reason?: string;
          p_type: Database["public"]["Enums"]["inventory_movement_type"];
        };
        Returns: string;
      };
      cancel_purchase: {
        Args: { p_purchase_id: string; p_reason: string };
        Returns: undefined;
      };
      cancel_sale: {
        Args: {
          p_reason: string;
          p_refund_method?: Database["public"]["Enums"]["payment_method"];
          p_sale_id: string;
        };
        Returns: undefined;
      };
      change_member_role: {
        Args: { p_business_id: string; p_role_code: string; p_user_id: string };
        Returns: undefined;
      };
      count_stock: {
        Args: {
          p_business_id: string;
          p_counted_quantity: number;
          p_location_id: string;
          p_product_id: string;
          p_reason?: string;
        };
        Returns: string;
      };
      create_business: {
        Args: {
          p_address?: string;
          p_city?: string;
          p_name: string;
          p_phone?: string;
        };
        Returns: string;
      };
      create_sale: {
        Args: {
          p_business_id: string;
          p_client_reference: string;
          p_customer_id?: string;
          p_discount_amount?: number;
          p_items: Json;
          p_location_id: string;
          p_notes?: string;
          p_payments?: Json;
        };
        Returns: string;
      };
      decline_invitation: {
        Args: { p_business_id: string };
        Returns: undefined;
      };
      get_my_permissions: {
        Args: { p_business_id: string };
        Returns: string[];
      };
      invite_member: {
        Args: { p_business_id: string; p_email: string; p_role_code: string };
        Returns: string;
      };
      leave_business: { Args: { p_business_id: string }; Returns: undefined };
      list_business_members: {
        Args: { p_business_id: string };
        Returns: {
          avatar_path: string;
          email: string;
          full_name: string;
          joined_at: string;
          phone: string;
          role_code: string;
          role_name: string;
          status: Database["public"]["Enums"]["member_status"];
          user_id: string;
        }[];
      };
      list_low_stock: {
        Args: { p_business_id: string; p_location_id?: string };
        Returns: {
          location_id: string;
          location_name: string;
          min_stock_level: number;
          product_id: string;
          product_name: string;
          quantity: number;
        }[];
      };
      list_my_invitations: {
        Args: Record<PropertyKey, never>;
        Returns: {
          business_id: string;
          business_name: string;
          invited_at: string;
          role_code: string;
          role_name: string;
        }[];
      };
      order_purchase: { Args: { p_purchase_id: string }; Returns: undefined };
      receive_purchase: { Args: { p_purchase_id: string }; Returns: undefined };
      record_customer_payment: {
        Args: {
          p_amount: number;
          p_customer_id: string;
          p_external_reference?: string;
          p_location_id: string;
          p_method: Database["public"]["Enums"]["payment_method"];
          p_note?: string;
        };
        Returns: string;
      };
      record_purchase_payment: {
        Args: {
          p_amount: number;
          p_external_reference?: string;
          p_location_id: string;
          p_method: Database["public"]["Enums"]["payment_method"];
          p_note?: string;
          p_purchase_id: string;
        };
        Returns: string;
      };
      remove_member: {
        Args: { p_business_id: string; p_user_id: string };
        Returns: undefined;
      };
      save_purchase: {
        Args: {
          p_business_id: string;
          p_discount_amount?: number;
          p_items: Json;
          p_location_id: string;
          p_notes?: string;
          p_purchase_id: string;
          p_supplier_id: string;
          p_supplier_reference?: string;
        };
        Returns: string;
      };
      set_customer_credit_limit: {
        Args: { p_credit_limit: number; p_customer_id: string };
        Returns: undefined;
      };
      set_member_status: {
        Args: {
          p_business_id: string;
          p_status: Database["public"]["Enums"]["member_status"];
          p_user_id: string;
        };
        Returns: undefined;
      };
      set_product_status: {
        Args: {
          p_product_id: string;
          p_status: Database["public"]["Enums"]["record_status"];
        };
        Returns: undefined;
      };
      transfer_stock: {
        Args: {
          p_business_id: string;
          p_from_location_id: string;
          p_product_id: string;
          p_quantity: number;
          p_reason?: string;
          p_to_location_id: string;
        };
        Returns: string;
      };
    };
    Enums: {
      business_status: "ACTIVE" | "SUSPENDED";
      customer_transaction_type:
        "CREDIT_SALE" | "PAYMENT" | "ADJUSTMENT" | "SALE_CANCELLATION";
      inventory_movement_type:
        | "INITIAL"
        | "PURCHASE"
        | "SALE"
        | "SALE_CANCELLATION"
        | "RETURN"
        | "ADJUSTMENT"
        | "TRANSFER_OUT"
        | "TRANSFER_IN"
        | "LOSS"
        | "DAMAGE";
      location_type: "STORE" | "WAREHOUSE";
      member_status: "INVITED" | "ACTIVE" | "SUSPENDED";
      payment_direction: "IN" | "OUT";
      payment_method:
        | "CASH"
        | "WAVE"
        | "ORANGE_MONEY"
        | "FREE_MONEY"
        | "CARD"
        | "BANK_TRANSFER"
        | "CHEQUE"
        | "OTHER";
      payment_status: "UNPAID" | "PARTIAL" | "PAID";
      purchase_status: "DRAFT" | "ORDERED" | "RECEIVED" | "CANCELLED";
      record_status: "ACTIVE" | "ARCHIVED";
      sale_status: "COMPLETED" | "CANCELLED";
    };
    CompositeTypes: {
      [_ in never]: never;
    };
  };
};

type DatabaseWithoutInternals = Omit<Database, "__InternalSupabase">;

type DefaultSchema = DatabaseWithoutInternals[Extract<
  keyof Database,
  "public"
>];

export type Tables<
  DefaultSchemaTableNameOrOptions extends
    | keyof (DefaultSchema["Tables"] & DefaultSchema["Views"])
    | { schema: keyof DatabaseWithoutInternals },
  TableName extends (DefaultSchemaTableNameOrOptions extends {
    schema: keyof DatabaseWithoutInternals;
  }
    ? keyof (DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"] &
        DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Views"])
    : never) = never,
> = DefaultSchemaTableNameOrOptions extends {
  schema: keyof DatabaseWithoutInternals;
}
  ? (DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"] &
      DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Views"])[TableName] extends {
      Row: infer R;
    }
    ? R
    : never
  : DefaultSchemaTableNameOrOptions extends keyof (DefaultSchema["Tables"] &
        DefaultSchema["Views"])
    ? (DefaultSchema["Tables"] &
        DefaultSchema["Views"])[DefaultSchemaTableNameOrOptions] extends {
        Row: infer R;
      }
      ? R
      : never
    : never;

export type TablesInsert<
  DefaultSchemaTableNameOrOptions extends
    keyof DefaultSchema["Tables"] | { schema: keyof DatabaseWithoutInternals },
  TableName extends (DefaultSchemaTableNameOrOptions extends {
    schema: keyof DatabaseWithoutInternals;
  }
    ? keyof DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"]
    : never) = never,
> = DefaultSchemaTableNameOrOptions extends {
  schema: keyof DatabaseWithoutInternals;
}
  ? DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"][TableName] extends {
      Insert: infer I;
    }
    ? I
    : never
  : DefaultSchemaTableNameOrOptions extends keyof DefaultSchema["Tables"]
    ? DefaultSchema["Tables"][DefaultSchemaTableNameOrOptions] extends {
        Insert: infer I;
      }
      ? I
      : never
    : never;

export type TablesUpdate<
  DefaultSchemaTableNameOrOptions extends
    keyof DefaultSchema["Tables"] | { schema: keyof DatabaseWithoutInternals },
  TableName extends (DefaultSchemaTableNameOrOptions extends {
    schema: keyof DatabaseWithoutInternals;
  }
    ? keyof DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"]
    : never) = never,
> = DefaultSchemaTableNameOrOptions extends {
  schema: keyof DatabaseWithoutInternals;
}
  ? DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"][TableName] extends {
      Update: infer U;
    }
    ? U
    : never
  : DefaultSchemaTableNameOrOptions extends keyof DefaultSchema["Tables"]
    ? DefaultSchema["Tables"][DefaultSchemaTableNameOrOptions] extends {
        Update: infer U;
      }
      ? U
      : never
    : never;

export type Enums<
  DefaultSchemaEnumNameOrOptions extends
    keyof DefaultSchema["Enums"] | { schema: keyof DatabaseWithoutInternals },
  EnumName extends (DefaultSchemaEnumNameOrOptions extends {
    schema: keyof DatabaseWithoutInternals;
  }
    ? keyof DatabaseWithoutInternals[DefaultSchemaEnumNameOrOptions["schema"]]["Enums"]
    : never) = never,
> = DefaultSchemaEnumNameOrOptions extends {
  schema: keyof DatabaseWithoutInternals;
}
  ? DatabaseWithoutInternals[DefaultSchemaEnumNameOrOptions["schema"]]["Enums"][EnumName]
  : DefaultSchemaEnumNameOrOptions extends keyof DefaultSchema["Enums"]
    ? DefaultSchema["Enums"][DefaultSchemaEnumNameOrOptions]
    : never;

export type CompositeTypes<
  PublicCompositeTypeNameOrOptions extends
    | keyof DefaultSchema["CompositeTypes"]
    | { schema: keyof DatabaseWithoutInternals },
  CompositeTypeName extends (PublicCompositeTypeNameOrOptions extends {
    schema: keyof DatabaseWithoutInternals;
  }
    ? keyof DatabaseWithoutInternals[PublicCompositeTypeNameOrOptions["schema"]]["CompositeTypes"]
    : never) = never,
> = PublicCompositeTypeNameOrOptions extends {
  schema: keyof DatabaseWithoutInternals;
}
  ? DatabaseWithoutInternals[PublicCompositeTypeNameOrOptions["schema"]]["CompositeTypes"][CompositeTypeName]
  : PublicCompositeTypeNameOrOptions extends keyof DefaultSchema["CompositeTypes"]
    ? DefaultSchema["CompositeTypes"][PublicCompositeTypeNameOrOptions]
    : never;

export const Constants = {
  public: {
    Enums: {
      business_status: ["ACTIVE", "SUSPENDED"],
      customer_transaction_type: [
        "CREDIT_SALE",
        "PAYMENT",
        "ADJUSTMENT",
        "SALE_CANCELLATION",
      ],
      inventory_movement_type: [
        "INITIAL",
        "PURCHASE",
        "SALE",
        "SALE_CANCELLATION",
        "RETURN",
        "ADJUSTMENT",
        "TRANSFER_OUT",
        "TRANSFER_IN",
        "LOSS",
        "DAMAGE",
      ],
      location_type: ["STORE", "WAREHOUSE"],
      member_status: ["INVITED", "ACTIVE", "SUSPENDED"],
      payment_direction: ["IN", "OUT"],
      payment_method: [
        "CASH",
        "WAVE",
        "ORANGE_MONEY",
        "FREE_MONEY",
        "CARD",
        "BANK_TRANSFER",
        "CHEQUE",
        "OTHER",
      ],
      payment_status: ["UNPAID", "PARTIAL", "PAID"],
      purchase_status: ["DRAFT", "ORDERED", "RECEIVED", "CANCELLED"],
      record_status: ["ACTIVE", "ARCHIVED"],
      sale_status: ["COMPLETED", "CANCELLED"],
    },
  },
} as const;
