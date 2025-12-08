export function RoomList({ currentRoom, setRoom }) {
  const rooms = ["general", "games", "projects"];

  return (
    <div className="room-list">
      {rooms.map((r) => (
        <div
          key={r}
          className={currentRoom === r ? "room-selected" : "room"}
          onClick={() => setRoom(r)}
        >
          #{r}
        </div>
      ))}
    </div>
  );
}
