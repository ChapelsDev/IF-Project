interface StatusBarProps {
  connected: boolean;
  nodeId: string;
}

export function StatusBar({ connected, nodeId }: StatusBarProps) {
  return (
    <div style={{ padding: "8px", background: "#222", color: "#fff" }}>
      Status: {connected ? "Connected" : "Disconnected"}  
      | Node: {nodeId}
    </div>
  );
}
