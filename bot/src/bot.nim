import dimscord, asyncdispatch, os, ws, json, strutils, terminal, re, times

let token = getEnv("DISCORD_TOKEN")
let agentWsUrl = getEnv("AGENT_WS_URL", "ws://agent:8000")
let discord = newDiscordClient(token)
let dataDir = "/app/data"
let schedulesFile = dataDir / "schedules.json"

if not dirExists(dataDir):
  createDir(dataDir)

type
  # 定期実行タスクのデータ構造
  Schedule = object
    prompt: string          # 実行するプロンプト
    intervalSeconds: int    # 実行間隔（秒）
    nextRun: float          # 次回実行時刻（Unixタイムスタンプ）
    channelId: string       # 実行結果を報告するチャンネルID

var schedules: seq[Schedule] = @[]
var botUser: User # ボット自身のユーザー情報（メンション検知用）

proc loadSchedules() =
  ## 永続化ストレージ（JSON）からスケジュールを読込
  if fileExists(schedulesFile):
    try:
      let content = readFile(schedulesFile)
      schedules = content.fromJson(seq[Schedule])
      echo "[報告] 設定ファイルから ", schedules.len, " 件のスケジュールを読込。"
    except:
      echo "[警告] スケジュールの読込に失敗。初期化を実行。"

proc saveSchedules() =
  ## 現在のスケジュール一覧を永続化ストレージに保存
  try:
    let data = $(%schedules)
    writeFile(schedulesFile, data)
  except:
    echo "[警告] スケジュールの保存に失敗。"

proc cleanAnsi(s: string): string =
  ## ANSIエスケープシーケンス（色付け等）を除去
  s.replace(re(r"\e\[[0-9;]*[mK]"), "")

proc executePrompt(prompt: string, channelId: string) {.async.} =
  ## AIエージェントにプロンプトを送信し、結果をDiscordにストリーミング出力する
  var retryCount = 0
  let maxRetries = 3
  var ws: WebSocket = nil

  # エージェントとのWebSocket接続を確立（最大3回試行）
  while retryCount < maxRetries:
    try:
      ws = await newWebSocket(agentWsUrl)
      break
    except Exception as e:
      retryCount.inc
      echo "[警告] WebSocket接続失敗 (試行 ", retryCount, "/", maxRetries, "): ", e.msg
      if retryCount < maxRetries:
        await sleepAsync(2000)
      else:
        discard await discord.api.sendMessage(channelId, "[警告] エージェントへの接続に失敗。")
        return

  try:
    await ws.send(prompt)
    
    var responseBuffer = ""
    var currentMsg: Message = nil
    
    # WebSocket経由でエージェントからの出力を順次受信
    while ws.readyState == Open:
      let data = await ws.receiveStrPacket()
      if data == "": break
      
      let cleanedData = cleanAnsi(data)
      if cleanedData == "": continue
      
      # Discordのメッセージ長制限（2000文字）を考慮したバッファリング
      if responseBuffer.len + cleanedData.len > 1900:
        if currentMsg == nil:
          currentMsg = await discord.api.sendMessage(channelId, "[報告] 実行出力:\n" & responseBuffer)
        else:
          discard await discord.api.editMessage(channelId, currentMsg.id, responseBuffer)
        
        responseBuffer = cleanedData
        currentMsg = nil # 残りの出力のために新しいメッセージを作成
      else:
        responseBuffer.add(cleanedData)
        if currentMsg == nil:
          currentMsg = await discord.api.sendMessage(channelId, "[報告] 実行中...\n" & responseBuffer)
        else:
          discard await discord.api.editMessage(channelId, currentMsg.id, "[報告] 実行中...\n" & responseBuffer)
    
    # 最終的なバッファをフラッシュ
    if responseBuffer.len > 0:
      if currentMsg == nil:
        discard await discord.api.sendMessage(channelId, "[報告] 実行結果:\n" & responseBuffer)
      else:
        discard await discord.api.editMessage(channelId, currentMsg.id, "[報告] 実行結果:\n" & responseBuffer)

    ws.close()
  except Exception as e:
    discard await discord.api.sendMessage(channelId, "[警告] 実行エラー: " & e.msg)

proc parseInterval(s: string): int =
  ## 時間間隔の文字列（例: 10m, 1時間）を秒数に変換
  let pattern = re"(\d+)(s|m|h|d|秒|分|時間|日)"
  var matches: array[2, string]
  if s.find(pattern, matches) != -1:
    let val = matches[0].parseInt()
    let unit = matches[1]
    
    if unit == "s" or unit == "秒": return val
    if unit == "m" or unit == "分": return val * 60
    if unit == "h" or unit == "時間": return val * 3600
    if unit == "d" or unit == "日": return val * 86400
    
  return 0

proc onMessageCreate(s: Shard, m: Message) {.async.} =
  ## Discordメッセージ受信時のイベントハンドラ
  if m.author.bot: return
  
  # ヘルプコマンド
  if m.content == "!help":
    let helpMsg = "[報告] 使用可能なコマンド:\n" &
      "!schedule \"プロンプト\" 間隔 (例: !schedule \"CPU使用率を確認\" 1h)\n" &
      "!schedules - 現在のスケジュール一覧を表示\n" &
      "!unschedule 番号 - スケジュールを削除\n" &
      "ボットへのメンション - 自由記述でAIエージェントに依頼"
    discard await discord.api.sendMessage(m.channel_id, helpMsg)
    return

  # スケジュール登録
  if m.content.startsWith("!schedule"):
    let pattern = re(""" "(.+)"\s+(\w+)""")
    var matches: array[2, string]
    if m.content.find(pattern, matches) != -1:
      let prompt = matches[0]
      let intervalStr = matches[1]
      let seconds = parseInterval(intervalStr)
      if seconds <= 0:
        discard await discord.api.sendMessage(m.channel_id, "[警告] 無効な時間間隔。")
        return
      let sched = Schedule(
        prompt: prompt,
        intervalSeconds: seconds,
        nextRun: epochTime() + seconds.float,
        channelId: m.channel_id
      )
      schedules.add(sched)
      saveSchedules()
      discard await discord.api.sendMessage(m.channel_id, "[了解] スケジュールを追加。")
    else:
      discard await discord.api.sendMessage(m.channel_id, "[警告] 書式不備。例: !schedule \"prompt\" 1h")
    return

  # 登録済みスケジュール一覧
  if m.content == "!schedules":
    var resp = "[報告] 現在のスケジュール一覧:\n"
    if schedules.len == 0:
      resp.add("登録されているスケジュールはありません。")
    for i, s in schedules:
      resp.add($i & ": \"" & s.prompt & "\" (" & $s.intervalSeconds & "s間隔)\n")
    discard await discord.api.sendMessage(m.channel_id, resp)
    return

  # スケジュール削除
  if m.content.startsWith("!unschedule"):
    let parts = m.content.split(' ')
    if parts.len < 2: return
    try:
      let idx = parts[1].parseInt()
      if idx >= 0 and idx < schedules.len:
        schedules.delete(idx)
        saveSchedules()
        discard await discord.api.sendMessage(m.channel_id, "[了解] スケジュールを削除。")
      else:
        discard await discord.api.sendMessage(m.channel_id, "[否定] 無効なインデックス。")
    except: discard
    return

  # ボットへの直接メンションに対する応答
  if m.content.contains("<@" & botUser.id & ">") or m.content.contains("<@!" & botUser.id & ">"):
    let fullPrompt = m.content.replace(re"<@!?[0-9]+>", "").strip()
    if fullPrompt == "": return

    # 自然言語によるスケジュール設定の試行 (例: "30分おきに..." )
    let schedulePattern = re(r"(\d+(?:s|m|h|d|秒|分|時間|日))(?:おきに|ごとに|間隔で)\s*(.+?)(?:して|報告|実行|$)")
    var schedMatches: array[2, string]
    
    if fullPrompt.find(schedulePattern, schedMatches) != -1:
      let intervalStr = schedMatches[0]
      let prompt = schedMatches[1].strip()
      let seconds = parseInterval(intervalStr)
      
      if seconds > 0 and prompt != "":
        let sched = Schedule(
          prompt: prompt,
          intervalSeconds: seconds,
          nextRun: epochTime() + seconds.float,
          channelId: m.channel_id
        )
        schedules.add(sched)
        saveSchedules()
        discard await discord.api.sendMessage(m.channel_id, "[了解] 定期命令を登録。間隔: " & intervalStr)
        return

    # 通常のプロンプト実行
    asyncCheck executePrompt(fullPrompt, m.channel_id)

proc schedulerLoop() {.async.} =
  ## 10秒ごとにスケジュールの期限を確認するメインループ
  while true:
    let now = epochTime()
    var changed = false
    for i in 0 ..< schedules.len:
      if now >= schedules[i].nextRun:
        echo "[報告] スケジュール実行: ", schedules[i].prompt
        asyncCheck executePrompt(schedules[i].prompt, schedules[i].channelId)
        schedules[i].nextRun = now + schedules[i].intervalSeconds.float
        changed = true
    if changed: saveSchedules()
    await sleepAsync(10000)

# Discord クライアントの準備完了時
discord.events.on_ready = proc (s: Shard, r: Ready) {.async.} =
  echo "[報告] ボット起動完了。ユーザー: ", r.user.username
  botUser = r.user
  loadSchedules()
  asyncCheck schedulerLoop() # スケジューラーの開始

# メッセージ受信イベントの割り当て
discord.events.message_create = onMessageCreate

# ゲートウェイインテント（サーバーからの通知を受け取るための設定）
waitFor discord.startSession(gateway_intents = {giGuilds, giGuildMessages, giMessageContent})
