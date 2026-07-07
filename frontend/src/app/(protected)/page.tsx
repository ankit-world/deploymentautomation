export default function ChatHomePage() {
  return (
    <div className="flex flex-1 items-center justify-center px-4 text-center">
      <div className="space-y-2">
        <h1 className="text-xl font-semibold">No conversation selected</h1>
        <p className="text-sm text-neutral-500">
          Pick a conversation from the sidebar, or start a new one.
        </p>
      </div>
    </div>
  );
}
