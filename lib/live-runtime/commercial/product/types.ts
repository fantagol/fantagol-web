import type { JsonObject } from "../json";

export interface GetCommercialProductsInput {
  currency?: string | null;
}

export interface CommercialProduct extends JsonObject {
  product_id: string;
  product_code: string;
  title: string;
  description: string;
  passes: number;
  price_minor: number;
  currency: string;
  sort_order: number;
  metadata: JsonObject;
}

export type CommercialProducts = CommercialProduct[];
