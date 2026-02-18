import asyncdispatch, asynchttpserver, ws, osproc, streams, asyncfile, os, strutils

let port = 8000
let agentWs = newAsyncHttpServer()

proc handleRequest(req: Request) {.async.} =
  if req.url.path == "/":
    try:
      var ws = await newWebSocket(req)
      echo "[報告] 新規接続を確立。"
      
      while ws.readyState == Open:
        let prompt = await ws.receiveStrPacket()
        if prompt == "": break
        echo "[報告] プロンプトを受信: ", prompt

        
        # Execute openhands as a subprocess
        # Command: openhands --headless -t <prompt> --always-approve --override-with-envs
        let process = startProcess(
          "openhands", 
          args = @["--headless", "-t", prompt, "--always-approve", "--override-with-envs", "--sandbox-plugins-path", "/app/skills"],
          workingDir = "/app/workspace",
          options = {poUsePath, poDaemon, poStdErrToStdOut}
        )
        
        let outputStream = process.outputStream
        var line = ""
        var hasOutput = false
        while true:
          if outputStream.readLine(line):
            if line != "":
              await ws.send(line & "\n")
              hasOutput = true
          elif not process.running:
            break
          await sleepAsync(10) # Avoid busy loop
          
        let exitCode = process.peekExitCode()
        process.close()
        
        if exitCode != 0:
          echo "[警告] プロセスが異常終了。終了コード: ", exitCode
          await ws.send("[警告] AIエージェントの実行中にエラーが発生（終了コード: " & $exitCode & "）。\n")
        elif not hasOutput:
          await ws.send("[報告] 実行完了（出力なし）。\n")
        
        echo "[報告] サブプロセス終了。"

      ws.close()
    except Exception as e:
      echo "[警告] WebSocketハンドラでエラー発生: ", e.msg
  else:
    await req.respond(Http404, "Not Found")

echo "[報告] Agent WebSocket サーバーをポート ", port, " で開始。"
waitFor agentWs.serve(Port(port), handleRequest)
