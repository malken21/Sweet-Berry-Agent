import dimscord, asyncdispatch, os, ws, json, strutils, terminal, re, times

let token = getEnv("DISCORD_TOKEN")
let agentWsUrl = getEnv("AGENT_WS_URL", "ws://agent:8000")
let discord = newDiscordClient(token)
let dataDir = "/app/data"
let schedulesFile = dataDir / "schedules.json"

if not dirExists(dataDir):
  createDir(dataDir)

type
  Schedule = object
    prompt: string
    intervalSeconds: int
    nextRun: float # unix timestamp
    channelId: string

var schedules: seq[Schedule] = @[]

proc loadSchedules() =
  if fileExists(schedulesFile):
    try:
      let content = readFile(schedulesFile)
      schedules = content.fromJson(seq[Schedule])
      echo "[報告] 設定ファイルから ", schedules.len, " 件のスケジュールを読込。"
    except:
      echo "[警告] スケジュールの読込に失敗。初期化を実行。"

proc saveSchedules() =
  try:
    let data = schedules.toJson()
    writeFile(schedulesFile, data)
  except:
    echo "[警告] スケジュールの保存に失敗。"

proc cleanAnsi(s: string): string =
  s.replace(re"\e\[[0-9;]*[mK]", "")

proc executePrompt(prompt: string, channelId: string) {.async.} =
  var retryCount = 0
  let maxRetries = 3
  var ws: WebSocket = nil

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
    
    while ws.readyState == Open:
      let data = await ws.receiveStr()
      if data == "": break
      
      let cleanedData = cleanAnsi(data)
      responseBuffer.add(cleanedData)
      
      if responseBuffer.len > 0:
        if currentMsg == nil:
          currentMsg = await discord.api.sendMessage(channelId, "[報告] 実行結果:\n" & responseBuffer)
        else:
          if responseBuffer.len < 1900:
            discard await discord.api.editMessage(channelId, currentMsg.id, "[報告] 実行結果:\n" & responseBuffer)
          else:
            currentMsg = await discord.api.sendMessage(channelId, "...")
            responseBuffer = cleanedData
            discard await discord.api.editMessage(channelId, currentMsg.id, responseBuffer)
    ws.close()
  except Exception as e:
    discard await discord.api.sendMessage(channelId, "[警告] 実行エラー: " & e.msg)

proc parseInterval(s: string): int =
  let pattern = re"(\d+)([smhd])"
  var matches: array[2, string]
  if s.find(pattern, matches) != -1:
    let val = matches[0].parseInt()
    let unit = matches[1][0]
    case unit
    of 's': return val
    of 'm': return val * 60
    of 'h': return val * 3600
    of 'd': return val * 86400
    else: return val
  return 0

proc onMessageCreate(s: DiscordSession, m: Message) {.async.} =
  if m.author.bot: return
  
  if m.content == "!help":
    let helpMsg = "[報告] 使用可能なコマンド:\n" &
      "!schedule \"プロンプト\" 間隔 (例: !schedule \"CPU使用率を確認\" 1h)\n" &
      "!schedules - 現在のスケジュール一覧を表示\n" &
      "!unschedule 番号 - スケジュールを削除\n" &
      "ボットへのメンション - 自由記述でAIエージェントに依頼"
    discard await discord.api.sendMessage(m.channel_id, helpMsg)
    return

  if m.content.startsWith("!schedule"):
    let pattern = re"\"(.+)\"\s+(\w+)"
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

  if m.content == "!schedules":
    var resp = "[報告] 現在のスケジュール一覧:\n"
    if schedules.len == 0:
      resp.add("登録されているスケジュールはありません。")
    for i, s in schedules:
      resp.add($i & ": \"" & s.prompt & "\" (" & $s.intervalSeconds & "s間隔)\n")
    discard await discord.api.sendMessage(m.channel_id, resp)
    return

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

  # Original logic for mentions
  if m.content.contains("<@" & s.user.id & ">") or m.content.contains("<@!" & s.user.id & ">"):
    let fullPrompt = m.content.replace(re"<@!?[0-9]+>", "").strip()
    if fullPrompt == "": return

    # 自然言語による定期実行命令の判定
    # 例: "1時間ごとに CPU使用率を確認して"
    let schedulePattern = re"(\d+[smhd])(?:おきに|ごとに|間隔で)\s*(.+?)(?:して|報告|実行|$)"
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
        discard await discord.api.sendMessage(m.channel_id, "[了解] 自然言語命令に基づきスケジュールを追加。内容: \"" & prompt & "\" (" & intervalStr & "間隔)")
        return

    try:
      let ws = await newWebSocket(agentWsUrl)
      await ws.send(fullPrompt)
      
      var responseBuffer = ""
      var currentMsg: Message = nil
      
      while ws.readyState == Open:
        let data = await ws.receiveStr()
        if data == "": break
        
        let cleanedData = cleanAnsi(data)
        responseBuffer.add(cleanedData)
        
        if responseBuffer.len > 0:
          if currentMsg == nil:
            currentMsg = await discord.api.sendMessage(m.channel_id, responseBuffer)
          else:
            if responseBuffer.len < 1900:
              discard await discord.api.editMessage(m.channel_id, currentMsg.id, responseBuffer)
            else:
              currentMsg = await discord.api.sendMessage(m.channel_id, "...")
              responseBuffer = cleanedData
              discard await discord.api.editMessage(m.channel_id, currentMsg.id, responseBuffer)
      ws.close()
    except Exception as e:
      discard await discord.api.sendMessage(m.channel_id, "[警告] 実行エラー: " & e.msg)
proc schedulerLoop() {.async.} =
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

discord.events.on_ready = proc (s: DiscordSession, r: Ready) {.async.} =
  echo "[報告] ボット起動完了。ユーザー: ", r.user.username
  loadSchedules()
  asyncCheck schedulerLoop()

discord.events.message_create = onMessageCreate

waitFor discord.startSession()
