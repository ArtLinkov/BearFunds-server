// Real Gemini-backed receipt parser. Reads GEMINI_API_KEY from the SERVER environment so
// the key never reaches the client bundle (Migration Playbook L1). Mirrors the former
// client geminiService request 1:1: same model, prompt, and structured-output schema, so
// the ParsedReceipt shape the client consumes is unchanged - only the transport moved.
// Model pin deferred ([Q5]); gemini-3-flash-preview is carried over as-is for now.
import { GoogleGenAI, Type } from "https://esm.sh/@google/genai@1";
import type { ParsedReceipt, ReceiptParser } from "./handler.ts";

const MODEL = "gemini-3-flash-preview";
const PROMPT =
  "Extract the following information from this receipt: entity name (the person or " +
  "business involved), total amount, and date. If possible, also suggest a category and " +
  "provide a brief description. Return the result in JSON format.";

export const geminiParser: ReceiptParser = async (base64Image: string): Promise<ParsedReceipt> => {
  const apiKey = Deno.env.get("GEMINI_API_KEY");
  if (!apiKey) throw new Error("GEMINI_API_KEY is not configured on the server.");

  const ai = new GoogleGenAI({ apiKey });
  const response = await ai.models.generateContent({
    model: MODEL,
    contents: [
      {
        parts: [
          { inlineData: { mimeType: "image/jpeg", data: base64Image } },
          { text: PROMPT },
        ],
      },
    ],
    config: {
      responseMimeType: "application/json",
      responseSchema: {
        type: Type.OBJECT,
        properties: {
          entity: { type: Type.STRING },
          amount: { type: Type.NUMBER },
          date: { type: Type.STRING, description: "YYYY-MM-DD format" },
          category: { type: Type.STRING },
          description: { type: Type.STRING },
        },
        required: ["entity", "amount", "date"],
      },
    },
  });

  const text = response.text;
  if (!text) throw new Error("Empty response from Gemini.");
  return JSON.parse(text) as ParsedReceipt;
};
