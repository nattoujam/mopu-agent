import config, github_app, log, process

proc createLabel(cfg: Config, name, color, description: string) =
  if ghRun(["label", "create", name, "-R", cfg.repo, "--color", color, "--description", description]).exitCode == 0:
    log "ラベルを作成しました: " & name
  else:
    log "ラベルは既に存在します: " & name

proc setupRepo(repo: string) =
  let cfg = loadConfig(repo)
  log "対象リポジトリ: " & cfg.repo
  discard setupAppAuth(cfg)
  createLabel(cfg, LabelQueued, "1d76db", "mopu-agent: 処理待ち")
  createLabel(cfg, LabelRunning, "fbca04", "mopu-agent: 実行中")
  createLabel(cfg, LabelAwaiting, "5319e7", "mopu-agent: 分解案の承認待ち")
  createLabel(cfg, LabelAwaitingInput, "c5def5", "mopu-agent: 質問への回答待ち")
  createLabel(cfg, LabelDone, "0e8a16", "mopu-agent: 完了")
  createLabel(cfg, LabelFailed, "d73a4a", "mopu-agent: 失敗")

proc setupMain*(args: seq[string]): int =
  var repos: seq[string]
  if args.len == 2 and args[0] == "--repo" and args[1].len > 0:
    repos = @[args[1]]
  elif args.len != 0:
    die "使い方: mopu setup [--repo owner/repo]"
  requireTools()
  discard loadGlobalConfig()
  if repos.len == 0:
    repos = repoNames(loadSettingsFile())
    if repos.len == 0:
      die "リポジトリが設定されていません。コンソールの「設定」で登録してください"
  var failed = false
  for r in repos:
    try:
      setupRepo(r)
    except Fatal as e:
      err e.msg
      warn r & " のセットアップに失敗しました"
      failed = true
  if failed:
    die "セットアップに失敗したリポジトリがあります"
  log "セットアップ完了。mopu poll --dry-run で動作を確認してください"
  0
