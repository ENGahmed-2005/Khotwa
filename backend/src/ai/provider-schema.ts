/**
 * Keep the provider's decoding grammar small; validate all values with the original
 * application schema after generation. Gemini documents that numeric/array bounds
 * and branching can exceed its grammar-state limit (HTTP 400 INVALID_ARGUMENT).
 * https://aistudio.google.com/docs/structured-output#simplifying-complex-schemas
 */
export function geminiResponseSchema(schema: Record<string, unknown>): Record<string, unknown> {
  const output: Record<string, unknown> = {};
  for (const [key, value] of Object.entries(schema)) {
    switch (key) {
      case 'type':
      case 'title':
      case 'description':
      case 'required':
      case 'enum':
        output[key] = structuredClone(value);
        break;
      case 'const':
        output.enum = [structuredClone(value)];
        break;
      case 'format':
        if (typeof value === 'string' && ['date', 'date-time', 'time'].includes(value)) output.format = value;
        else if (value === 'uuid') output.description = `${typeof schema.description === 'string' ? `${schema.description} ` : ''}A valid UUID string.`;
        break;
      case 'properties':
        output.properties = Object.fromEntries(Object.entries(asObject(value)).map(([name, child]) => [name, geminiResponseSchema(asObject(child))]));
        break;
      case 'items':
        output.items = geminiResponseSchema(asObject(value));
        break;
      case 'additionalProperties':
        output.additionalProperties = typeof value === 'boolean' ? value : geminiResponseSchema(asObject(value));
        break;
      case 'oneOf':
      case 'anyOf':
        if (!Array.isArray(value)) throw new Error('Invalid provider schema union');
        output.anyOf = value.map(child => geminiResponseSchema(asObject(child)));
        break;
      // Bounds, patterns and unsupported keywords stay exclusively in application validation.
    }
  }
  return output;
}

function asObject(value: unknown): Record<string, unknown> {
  if (!value || typeof value !== 'object' || Array.isArray(value)) throw new Error('Invalid provider schema object');
  return value as Record<string, unknown>;
}
