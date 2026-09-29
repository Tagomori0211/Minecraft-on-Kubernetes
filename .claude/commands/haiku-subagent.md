---
description: サブエージェント展開ガイドライン（model=haiku 必須・プロジェクト固有ルール明記）
---

# サブエージェント展開ガイドライン

このプロジェクトでは必要に応じてサブエージェントを展開できる。ただし以下のルールを厳守すること。

## モデル指定（必須）

**サブエージェントは必ず `model: "haiku"` を指定すること。**

```
Agent(
  subagent_type="...",
  model="haiku",
  prompt="...",
  ...
)
```

## 使いどころ

| ユースケース | 理由 |
|---|---|
| 並行SSHチェック（複数サーバーのログ同時確認） | メインコンテキストを圧迫しない |
| 大量ログの解析・フィルタリング | 長大な出力をサブで処理 |
| Explore（ファイル検索・コード調査） | `subagent_type="Explore"` を使用 |
| 独立したリサーチ（ドキュメント調査など） | メインの作業と並行して実行 |

## プロジェクト固有の必須ルール（サブエージェントにも適用）

サブエージェントのプロンプトには必ず以下を明記すること:

1. **出力は日本語**（CLAUDE.md ルール）
2. **kubectl / helm は必ず `ssh k3s-worker 'sudo kubectl ...'` 経由で実行**（クライアントからの直接実行不可）
3. **pod再起動は `replicas=0 → 1` のみ**（`rollout restart` 禁止）
4. **SSH内では `&&` 可**（CLAUDE.md の `&&` 禁止はローカルシェルのみ）

## 使用例

```python
Agent(
  subagent_type="general-purpose",
  model="haiku",
  description="minecraft namespace pod状態確認",
  prompt="""
    以下のコマンドを実行してpod状態を確認し、結果を日本語でレポートしてください。
    kubectl/helmはSSH経由のみ実行可能です。

    ssh k3s-worker 'sudo kubectl get pods -n minecraft -o wide'
    ssh k3s-worker 'sudo kubectl logs deploy/deploy-survival -c minecraft -n minecraft --tail=50'
  """
)
```

## 禁止事項

- `model: "haiku"` 以外のモデルを使用すること
- ローカルで直接 `kubectl` / `helm` を実行するプロンプトを書くこと
- `kubectl rollout restart` を含むプロンプトを書くこと
