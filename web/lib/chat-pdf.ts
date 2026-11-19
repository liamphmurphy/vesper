// PDF cards in chat: a ```pdf fence holds the library_item_id of a PDF saved
// to the person's Library (components/domain/pdf-fence). Kept free of React so
// `npm run test:unit` covers it.

export const isPdfFence = (info: string | undefined) => (info ?? "").trim().split(/\s+/)[0]?.toLowerCase() === "pdf";

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

/** The library item id in a ```pdf fence, or null when it holds anything else. */
export function parsePdfFence(code: string): string | null {
  const id = code.trim();
  return UUID.test(id) ? id.toLowerCase() : null;
}
