// Sealing what goes to the relay: JSON → deflate → AES-GCM with the scene's
// key (which only lives in share links) → base64 of iv + ciphertext.

import {
  IV_LENGTH_BYTES,
  decryptData,
  encryptData,
} from "@excalidraw/excalidraw/data/encryption";

const toBase64 = (bytes: Uint8Array) => {
  let binary = "";
  const chunk = 0x8000;
  for (let i = 0; i < bytes.length; i += chunk) {
    binary += String.fromCharCode(...bytes.subarray(i, i + chunk));
  }
  return btoa(binary);
};

const fromBase64 = (text: string) => {
  const binary = atob(text);
  const bytes = new Uint8Array(binary.length);
  for (let i = 0; i < binary.length; i++) {
    bytes[i] = binary.charCodeAt(i);
  }
  return bytes;
};

const pipe = async (
  bytes: Uint8Array<ArrayBuffer>,
  stream: CompressionStream | DecompressionStream,
) =>
  new Uint8Array(
    await new Response(
      new Blob([bytes]).stream().pipeThrough(stream),
    ).arrayBuffer(),
  );

export const seal = async (key: string, value: unknown): Promise<string> => {
  const json = new TextEncoder().encode(JSON.stringify(value));
  const packed = await pipe(json, new CompressionStream("deflate-raw"));
  const { encryptedBuffer, iv } = await encryptData(key, packed);
  const out = new Uint8Array(IV_LENGTH_BYTES + encryptedBuffer.byteLength);
  out.set(iv, 0);
  out.set(new Uint8Array(encryptedBuffer), IV_LENGTH_BYTES);
  return toBase64(out);
};

export const unseal = async <T>(key: string, sealed: string): Promise<T> => {
  const bytes = fromBase64(sealed);
  const iv = bytes.slice(0, IV_LENGTH_BYTES);
  const packed = await decryptData(iv, bytes.slice(IV_LENGTH_BYTES), key);
  const json = await pipe(
    new Uint8Array(packed),
    new DecompressionStream("deflate-raw"),
  );
  return JSON.parse(new TextDecoder().decode(json)) as T;
};
