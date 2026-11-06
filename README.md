# 营养好习惯

每天打卡，和伙伴一起养一盆健康花。客人点伙伴发的链接就能用，不用下载。

- `index.html`：客人用的网页（正式版）。伙伴链接是 `?p=伙伴代码`，示范模式是 `?demo`
- 三个计划：基础营养、体重管理、美肌保养。伙伴链接加 `&plan=weight` 或 `&plan=skin`，客人注册时会预先选好计划
- 30天健康好习惯挑战：日期、奖品和规则在 `index.html` 和 `team.html` 里的 `CHAL`（11月23日开放报名，12月1日开始，30 天里打卡满 25 天完成；`prize` 是完成送的礼物）。星期几和日期都跟着 `CHAL` 自动算。`codes` 留空 = 整个团队；只给某几位伙伴的客人，就填她们的伙伴代码
- WhatsApp 链接预览：挑战期间用 `og-chal.jpg` 和挑战的标题；挑战结束后把 `index.html` 里的 og 标签换回 `og.jpg`
- 还没吃营养品的朋友：链接加 `&nu=1`（后台「我的链接」有现成的），她的打卡按钮是「我喝了今天第一杯水」。客人自己的邀请链接带 `&r=她的代码`，后台看得到谁带了谁
- `team.html`：团队后台。伙伴看自己的客人、跟进和礼物；领导看全团队、批准伙伴
- `supabase/schema.sql`：资料表和权限设定（在 Supabase SQL Editor 执行）
- `supabase/update-2-flowers.sql`：伙伴送花、今天一起浇水的人数（已经在用的资料库，执行这一段一次就好）
- `qrcode.js`：产生伙伴二维码（MIT，Kazuhiko Arase）
- `manifest.webmanifest`、`icon-*.png`：加到手机主屏幕时的名称和图标
