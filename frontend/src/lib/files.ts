import { API_BASE_URL, ApiError, tryRefresh } from "./api";

export type FileKind = "image" | "pdf" | "docx" | "xlsx" | "other";

export interface FileOut {
  id: string;
  conversation_id: string;
  filename: string;
  mimetype: string;
  kind: FileKind;
  size: number;
  extracted_text_preview: string | null;
  created_at: string;
}

/**
 * Uploads a file to `POST /conversations/{id}/files` (multipart/form-data, field name `file`).
 * Uses XMLHttpRequest instead of `fetch` solely because `fetch` has no upload-progress event —
 * `xhr.upload.onprogress` is the only way to drive a real progress bar for a large PDF/xlsx
 * upload. Everything else (cookie auth, 401-refresh-and-retry) mirrors `apiFetch` in `api.ts`.
 */
export async function uploadFile(
  conversationId: string,
  file: File,
  onProgress?: (percent: number) => void,
  _isRetry = false,
): Promise<FileOut> {
  return new Promise<FileOut>((resolve, reject) => {
    const xhr = new XMLHttpRequest();
    xhr.open("POST", `${API_BASE_URL}/conversations/${conversationId}/files`);
    xhr.withCredentials = true;

    xhr.upload.onprogress = (event) => {
      if (event.lengthComputable && onProgress) {
        onProgress(Math.round((event.loaded / event.total) * 100));
      }
    };

    xhr.onload = () => {
      void (async () => {
        if (xhr.status === 401 && !_isRetry) {
          const refreshed = await tryRefresh();
          if (refreshed) {
            try {
              resolve(await uploadFile(conversationId, file, onProgress, true));
            } catch (err) {
              reject(err);
            }
            return;
          }
          reject(new ApiError(401, "Not authenticated"));
          return;
        }

        if (xhr.status >= 200 && xhr.status < 300) {
          try {
            resolve(JSON.parse(xhr.responseText) as FileOut);
          } catch {
            reject(new ApiError(xhr.status, "Server returned an invalid response"));
          }
          return;
        }

        let detail = xhr.statusText || `Upload failed with status ${xhr.status}`;
        try {
          const body = JSON.parse(xhr.responseText);
          if (typeof body?.detail === "string") detail = body.detail;
        } catch {
          // non-JSON error body; keep the fallback detail
        }
        reject(new ApiError(xhr.status, detail));
      })();
    };

    xhr.onerror = () => reject(new ApiError(0, "Network error during upload"));
    xhr.onabort = () => reject(new ApiError(0, "Upload cancelled"));

    const formData = new FormData();
    formData.append("file", file);
    xhr.send(formData);
  });
}

/**
 * Fetches the raw bytes of an attachment from `GET /conversations/{id}/files/{fileId}/download`.
 *
 * Deliberately fetch-as-blob rather than a bare `<a href>`/`<img src>` pointed straight at the
 * backend: the endpoint requires the httpOnly auth cookie, and while it *would* be sent (same-site
 * localhost:3000/:8000, see docs/ARCHITECTURE.md), the backend sets
 * `Content-Disposition: attachment` on every response from this route, including image kinds.
 * That header's effect on an `<img>` subresource load is inconsistent across browsers, so relying
 * on it for inline thumbnails is fragile. Fetching as a blob and building an object URL works
 * identically for previews and downloads and sidesteps that ambiguity entirely.
 */
export async function fetchFileBlob(
  conversationId: string,
  fileId: string,
  _isRetry = false,
): Promise<Blob> {
  const res = await fetch(
    `${API_BASE_URL}/conversations/${conversationId}/files/${fileId}/download`,
    { credentials: "include" },
  );

  if (res.status === 401 && !_isRetry) {
    const refreshed = await tryRefresh();
    if (refreshed) return fetchFileBlob(conversationId, fileId, true);
  }

  if (!res.ok) {
    throw new ApiError(res.status, res.statusText || "Download failed");
  }
  return res.blob();
}

/** Fetches an attachment's bytes and triggers a browser save via a throwaway object URL/anchor. */
export async function downloadFile(
  conversationId: string,
  fileId: string,
  filename: string,
): Promise<void> {
  const blob = await fetchFileBlob(conversationId, fileId);
  const url = URL.createObjectURL(blob);
  try {
    const anchor = document.createElement("a");
    anchor.href = url;
    anchor.download = filename;
    document.body.appendChild(anchor);
    anchor.click();
    anchor.remove();
  } finally {
    URL.revokeObjectURL(url);
  }
}
