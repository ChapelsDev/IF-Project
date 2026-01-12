import { useState } from "react";
import axios from "axios";

interface FileUploadTestProps {
  backendUrl: string;
}

export function FileUploadTest({ backendUrl }: FileUploadTestProps) {
  const [selectedFile, setSelectedFile] = useState<File | null>(null);
  const [result, setResult] = useState<string>("");
  const [loading, setLoading] = useState(false);

  const handleFileSelect = (e: React.ChangeEvent<HTMLInputElement>) => {
    if (e.target.files && e.target.files[0]) {
      setSelectedFile(e.target.files[0]);
      setResult("");
    }
  };

  const handleUpload = async () => {
    if (!selectedFile) {
      setResult("❌ Please select a file first!");
      return;
    }

    setLoading(true);
    setResult("⏳ Uploading to SeaweedFS...");

    try {
      // Read file as base64
      const reader = new FileReader();
      reader.onload = async () => {
        try {
          const base64 = reader.result?.toString().split(',')[1];
          
          const response = await axios.post(`${backendUrl}/upload`, {
            filename: selectedFile.name,
            data: base64
          });

          setResult(`✅ SUCCESS!\n\nFile URL: ${response.data.fileUrl}\n\nSeaweedFS is working! 🎉`);
        } catch (error: any) {
          setResult(`❌ Upload failed: ${error.response?.data?.error || error.message}`);
        } finally {
          setLoading(false);
        }
      };
      reader.readAsDataURL(selectedFile);
    } catch (error: any) {
      setResult(`❌ Error: ${error.message}`);
      setLoading(false);
    }
  };

  return (
    <div style={{
      position: 'fixed',
      top: '20px',
      right: '20px',
      background: 'white',
      padding: '20px',
      borderRadius: '8px',
      boxShadow: '0 2px 10px rgba(0,0,0,0.1)',
      minWidth: '300px',
      zIndex: 1000
    }}>
      <h3 style={{ margin: '0 0 15px 0', color: '#333' }}>🧪 SeaweedFS Test</h3>
      
      <input 
        type="file" 
        onChange={handleFileSelect}
        style={{ marginBottom: '10px', display: 'block', width: '100%' }}
      />
      
      <button 
        onClick={handleUpload}
        disabled={!selectedFile || loading}
        style={{
          width: '100%',
          padding: '10px',
          background: selectedFile && !loading ? '#4CAF50' : '#ccc',
          color: 'white',
          border: 'none',
          borderRadius: '4px',
          cursor: selectedFile && !loading ? 'pointer' : 'not-allowed',
          fontWeight: 'bold'
        }}
      >
        {loading ? '⏳ Uploading...' : '📤 Upload to SeaweedFS'}
      </button>

      {result && (
        <pre style={{
          marginTop: '15px',
          padding: '10px',
          background: result.includes('✅') ? '#e8f5e9' : '#ffebee',
          borderRadius: '4px',
          fontSize: '12px',
          whiteSpace: 'pre-wrap',
          wordBreak: 'break-all'
        }}>
          {result}
        </pre>
      )}
      
      <p style={{ fontSize: '11px', color: '#666', marginTop: '10px', marginBottom: 0 }}>
        Select any file and click upload. If successful, the file is stored in SeaweedFS!
      </p>
    </div>
  );
}
