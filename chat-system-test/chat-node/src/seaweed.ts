import axios from 'axios';
import FormData from 'form-data';
import { Readable } from 'stream';

const FILER_URL = process.env.FILESTORE_URL || 'http://localhost:8888';
const UPLOAD_PATH = '/chat-files'; // Base path for all chat file uploads

interface UploadResult {
  success: boolean;
  fileUrl?: string;
  fileName?: string;
  error?: string;
}

interface FileInfo {
  name: string;
  size: number;
  mimeType: string;
}

/**
 * Upload a file to SeaweedFS via the filer
 * @param buffer File buffer or base64 string
 * @param fileName Original file name
 * @param username Username of the uploader (for organizing files)
 * @param filerUrl Optional custom filer URL (overrides default)
 * @returns Upload result with file URL
 */
export async function uploadToSeaweed(
  buffer: Buffer | string,
  fileName: string,
  username: string = 'anonymous',
  filerUrl?: string
): Promise<UploadResult> {
  try {
    const targetFiler = filerUrl || FILER_URL;
    
    // Convert base64 to buffer if needed
    const fileBuffer = typeof buffer === 'string' 
      ? Buffer.from(buffer, 'base64') 
      : buffer;

    // Create unique filename with timestamp
    const timestamp = Date.now();
    const sanitizedFileName = fileName.replace(/[^a-zA-Z0-9.-]/g, '_');
    const uniqueFileName = `${timestamp}_${sanitizedFileName}`;
    
    // Organize files by username and date
    const date = new Date().toISOString().split('T')[0];
    const uploadDir = `${UPLOAD_PATH}/${username}/${date}`;
    const fullPath = `${uploadDir}/${uniqueFileName}`;

    // Upload to SeaweedFS Filer
    const form = new FormData();
    form.append('file', fileBuffer, {
      filename: sanitizedFileName,
      contentType: getMimeType(fileName)
    });

    const response = await axios.post(`${targetFiler}${fullPath}`, form, {
      headers: {
        ...form.getHeaders(),
      },
      timeout: 30000, // 30 second timeout
      maxBodyLength: 10 * 1024 * 1024, // 10MB max file size
    });

    if (response.status === 201 || response.status === 200) {
      return {
        success: true,
        fileUrl: `${targetFiler}${fullPath}`,
        fileName: uniqueFileName
      };
    } else {
      return {
        success: false,
        error: `Upload failed with status ${response.status}`
      };
    }
  } catch (error: any) {
    console.error('[SEAWEED] Upload error:', error.message);
    return {
      success: false,
      error: error.message || 'Upload failed'
    };
  }
}

/**
 * Download a file from SeaweedFS
 * @param filePath Full file path on SeaweedFS
 * @param filerUrl Optional custom filer URL (overrides default)
 * @returns File buffer or null if failed
 */
export async function downloadFromSeaweed(filePath: string, filerUrl?: string): Promise<Buffer | null> {
  try {
    const targetFiler = filerUrl || FILER_URL;
    
    // Ensure path starts with /
    const cleanPath = filePath.startsWith('/') ? filePath : `/${filePath}`;
    
    const response = await axios.get(`${targetFiler}${cleanPath}`, {
      responseType: 'arraybuffer',
      timeout: 30000
    });

    return Buffer.from(response.data);
  } catch (error: any) {
    console.error('[SEAWEED] Download error:', error.message);
    return null;
  }
}

/**
 * Delete a file from SeaweedFS
 * @param filePath Full file path on SeaweedFS
 * @returns Success status
 */
export async function deleteFromSeaweed(filePath: string): Promise<boolean> {
  try {
    const cleanPath = filePath.startsWith('/') ? filePath : `/${filePath}`;
    
    await axios.delete(`${FILER_URL}${cleanPath}`, {
      timeout: 10000
    });

    return true;
  } catch (error: any) {
    console.error('[SEAWEED] Delete error:', error.message);
    return false;
  }
}

/**
 * List files in a directory
 * @param dirPath Directory path to list
 * @returns Array of file information
 */
export async function listFiles(dirPath: string = UPLOAD_PATH): Promise<FileInfo[]> {
  try {
    const cleanPath = dirPath.startsWith('/') ? dirPath : `/${dirPath}`;
    
    const response = await axios.get(`${FILER_URL}${cleanPath}`, {
      timeout: 10000
    });

    // Parse the directory listing (SeaweedFS returns JSON)
    if (response.data && response.data.Entries) {
      return response.data.Entries.map((entry: any) => ({
        name: entry.FullPath || entry.Name,
        size: entry.FileSize || 0,
        mimeType: entry.Mime || 'application/octet-stream'
      }));
    }

    return [];
  } catch (error: any) {
    console.error('[SEAWEED] List error:', error.message);
    return [];
  }
}

/**
 * Get MIME type from file extension
 */
function getMimeType(fileName: string): string {
  const ext = fileName.split('.').pop()?.toLowerCase();
  
  const mimeTypes: { [key: string]: string } = {
    // Images
    'jpg': 'image/jpeg',
    'jpeg': 'image/jpeg',
    'png': 'image/png',
    'gif': 'image/gif',
    'webp': 'image/webp',
    'svg': 'image/svg+xml',
    
    // Documents
    'pdf': 'application/pdf',
    'doc': 'application/msword',
    'docx': 'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
    'xls': 'application/vnd.ms-excel',
    'xlsx': 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
    'txt': 'text/plain',
    
    // Archives
    'zip': 'application/zip',
    'rar': 'application/x-rar-compressed',
    '7z': 'application/x-7z-compressed',
    
    // Audio/Video
    'mp3': 'audio/mpeg',
    'mp4': 'video/mp4',
    'avi': 'video/x-msvideo',
    'mov': 'video/quicktime',
    
    // Code
    'js': 'application/javascript',
    'json': 'application/json',
    'html': 'text/html',
    'css': 'text/css',
  };
  
  return mimeTypes[ext || ''] || 'application/octet-stream';
}

/**
 * Check if SeaweedFS is available
 */
export async function checkSeaweedHealth(): Promise<boolean> {
  try {
    const response = await axios.get(`${FILER_URL}/`, {
      timeout: 5000
    });
    return response.status === 200;
  } catch (error) {
    return false;
  }
}

export { FILER_URL, UPLOAD_PATH };
