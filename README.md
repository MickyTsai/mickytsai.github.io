# mickytsai.com

MickyTsai 的個人部落格，記錄 iOS 開發筆記、讀書亂想與生活點滴。

🌐 **[mickytsai.com](https://mickytsai.com)**

## 技術架構

- [Jekyll](https://jekyllrb.com/) 靜態網站生成器
- [Chirpy Jekyll Theme](https://github.com/cotes2020/jekyll-theme-chirpy/) v7.x
- [ZMediumToMarkdown](https://github.com/ZhgChgLi/ZMediumToMarkdown) — 自動從 Medium 匯入文章

## 本地開發

```bash
bundle install
bundle exec jekyll serve
```

## 使用 Ulysses 寫作

新文章在 Ulysses 的原生 `MyBlog` 專案中撰寫，第一個 H1 作為文章標題，
第一段文字作為摘要。圖片可以直接嵌入文章。

完成後將單篇文章匯出為 TextBundle，並從分享選單執行「發布 MyBlog」捷徑。
發布器會自動完成：

- 產生 Jekyll Front Matter、文章檔名與永久網址
- 將圖片放入 `assets/posts/<文章網址>/`
- 執行正式環境建置及 HTML 檢查
- 只提交該篇文章及其圖片，然後推送 `main`

發布前可以在終端機執行不寫入檔案的完整檢查：

```bash
ruby tools/myblog check "/path/to/article.textbundle" \
  --category "Micky's Life" \
  --tags "Ulysses,Writing"
```
