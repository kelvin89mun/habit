# 营养好习惯

每天打卡，和伙伴一起养一盆健康花。客人点伙伴发的链接就能用，不用下载。

- `index.html`：客人用的网页（正式版）。伙伴链接是 `?p=伙伴代码`，示范模式是 `?demo`
- 三个计划：基础营养、体重管理、美肌保养。伙伴链接加 `&plan=weight` 或 `&plan=skin`，客人注册时会预先选好计划
- `team.html`：团队后台。伙伴看自己的客人、跟进和礼物；领导看全团队、批准伙伴
- `supabase/schema.sql`：资料表和权限设定（在 Supabase SQL Editor 执行）
- `qrcode.js`：产生伙伴二维码（MIT，Kazuhiko Arase）
- `manifest.webmanifest`、`icon-*.png`：加到手机主屏幕时的名称和图标
