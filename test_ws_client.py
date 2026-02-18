import asyncio
import websockets
import sys

async def test_agent():
    uri = "ws://localhost:8000"
    try:
        async with websockets.connect(uri) as websocket:
            print(f"[INFO] Connected to {uri}")
            
            # Test prompt
            prompt = "echo 'Hello from test client'"
            print(f"[INFO] Sending prompt: {prompt}")
            await websocket.send(prompt)
            
            while True:
                try:
                    response = await asyncio.wait_for(websocket.recv(), timeout=10.0)
                    print(f"[RECV] {response.strip()}")
                    
                    if "実行完了" in response or "エラー" in response:
                        break
                except asyncio.TimeoutError:
                    print("[WARN] Response timeout")
                    break
                except websockets.exceptions.ConnectionClosed:
                    print("[INFO] Connection closed")
                    break

    except Exception as e:
        print(f"[ERROR] Failed to connect or communicate: {e}")
        sys.exit(1)

if __name__ == "__main__":
    asyncio.run(test_agent())
