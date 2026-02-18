import asyncdispatch, asynchttpserver, ws, osproc, streams, asyncfile, os, strutils

let port = 8000
let agentWs = newAsyncHttpServer()

proc handleRequest(req: Request) {.async.} =
  ## HTTPリクエストを待機し、WebSocketへのアップグレードを処理する
  if req.url.path == "/":
    try:
      var ws = await newWebSocket(req)
      echo "[報告] 新規接続を確立。"
      
      while ws.readyState == Open:
        # ボットからの指示（プロンプト）を受信
        let prompt = await ws.receiveStrPacket()
        if prompt == "": break
        echo "[報告] プロンプトを受信: ", prompt

        # AIエージェント(OpenHands)をサブプロセスとして起動
        # 注意：
        # --headless: GUIなしで実行
        # -t: プロンプト（指示内容）
        # --always-approve: 全ての操作を自動承認（エージェントが自律的に動くため）
        # --sandbox-plugins-path /app/skills: カスタムスキルの読込先
        let process = startProcess(
          "openhands", 
          args = @["--headless", "-t", prompt, "--always-approve", "--override-with-envs", "--sandbox-plugins-path", "/app/skills"],
          workingDir = "/app/workspace",
          options = {poUsePath, poDaemon, poStdErrToStdOut}
        )
        
        let outputStream = process.outputStream
        var line = ""
        var hasOutput = false
        
        # サブプロセスからの標準出力をリアルタイムで読込、WebSocket経由でボットへ送信
        while true:
          if outputStream.readLine(line):
            if line != "":
              await ws.send(line & "\n")
              hasOutput = true
          elif not process.running:
            # プロセスが終了しており、ストリームにも残データがない場合にループを脱出
            break
          await sleepAsync(10) # CPU負荷軽減のための短いスリープ
          
        let exitCode = process.peekExitCode()
        process.close()
        
        # 実行結果の状態をログおよびボットへ通知
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
    # ルートパス以外へのアクセスは404を返す
    await req.respond(Http404, "Not Found")

echo "[報告] Agent WebSocket サーバーをポート ", port, " で開始。"
waitFor agentWs.serve(Port(port), handleRequest)
