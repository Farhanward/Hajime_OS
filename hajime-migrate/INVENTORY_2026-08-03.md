# جرد سيرفر CarbonFlow — 2026-08-03

المصدر: قراءة مباشرة عبر SSH من `192.168.100.59`. كل الأوامر للقراءة فقط.

## العتاد

| البند | القيمة |
|---|---|
| المضيف | `carbonflow-tech` |
| النظام | Alpine Linux، نواة 6.18.34-0-lts |
| المعالج | Intel i7-7700 @ 3.60GHz، 8 خيوط |
| الذاكرة | **7.7 GB إجمالي، 3.5 GB مستخدم، 3.7 GB متاح** |
| السواب | **54 GB إجمالي، 4.3 GB مستخدم** |
| القرص الجذر | `/dev/sda1` 20 GB، مستخدم 52% |
| قرص البيانات | `/dev/sda3` 423 GB على `/vault`، مستخدم 88 GB، متاح 314 GB |
| مدة التشغيل | 23 يوماً |

الجهاز مطابق لما ورد في الخطة الأصلية. يؤكد ميزانية الذاكرة في `PLAN.md`.

**إشارة ضغط:** 4.3 GB سواب مستخدم مع توفر 3.7 GB رام يعني أن النظام تجاوز
ذاكرته الفعلية في وقت ما ورحّل صفحات للقرص. أي حمل إضافي يزيد هذا.

## الحاويات: 26 حاوية عاملة

المرجع القديم ذكر 17. العدد الفعلي 26.

| الحاوية | الصورة |
|---|---|
| carbonflow-cloakbrowser | cloakhq/cloakbrowser |
| carbonflow-cloudflared | cloudflare/cloudflared |
| carbonflow-control-panel | carbonflow/control-panel:local |
| carbonflow-crowdsec | crowdsecurity/crowdsec |
| carbonflow-litecart | carbonflow/litecart:local |
| carbonflow-litecart-db | mariadb:11.4 |
| carbonflow-n8n | n8nio/n8n |
| carbonflow-npm | jc21/nginx-proxy-manager |
| carbonflow-npm-db | mariadb:11.4 |
| carbonflow-ollama | ollama/ollama |
| carbonflow-owner-agent | carbonflow/owner-agent:local |
| carbonflow-portfolio | nginx:alpine |
| carbonflow-release-api | carbonflow/release-api:local |
| carbonflow-telegram-openai-bot | carbonflow/telegram-openai-bot:local |
| carbonflow-telemetry-api | carbonflow/telemetry-api:local |
| carbonflow-uptime-kuma | louislam/uptime-kuma:1 |
| carbonflow-waha | devlikeapro/waha:noweb |
| fatmalens-album | fatmalens-fatmalens-album |
| fatmalens-tunnel | cloudflare/cloudflared |
| postiz | ghcr.io/gitroomhq/postiz-app |
| postiz-postgres | postgres:17-alpine |
| postiz-redis | redis:7-alpine |
| postiz-temporal | temporalio/auto-setup:1.25.2 |
| postiz-temporal-es | elasticsearch:7.17.27 |
| qood-caddy | caddy:2-alpine |
| qood-orders | qood-orders-qood-orders |

خدمات غير مذكورة في `MASTER_REFERENCE.md`: `qood-caddy`، `qood-orders`،
`carbonflow-portfolio`، `carbonflow-telemetry-api`، `fatmalens-album`،
`carbonflow-uptime-kuma`، `carbonflow-owner-agent`.

## استهلاك الذاكرة الفعلي

| الحاوية | الاستهلاك |
|---|---|
| postiz-temporal-es | 397.9 MiB |
| postiz | 316.7 MiB |
| postiz-temporal | 241.3 MiB |
| carbonflow-n8n | 151.4 MiB (سقف 768 MiB) |
| postiz-postgres | 99.9 MiB |
| carbonflow-waha | 76.4 MiB (سقف 1 GiB) |
| carbonflow-uptime-kuma | 72.8 MiB |
| carbonflow-crowdsec | 43.4 MiB |

## أثر الجرد على الخطة

**قرار استبدال n8n يحتاج مراجعة.** الخطة الأصلية بنت الحجة على أن n8n يستهلك
350 MB. القياس الفعلي 151 MB. استبداله بـ Rust يوفّر حوالي 130 MB، وهو مكسب
متواضع مقابل عدة جلسات عمل.

المستهلك الحقيقي هو حزمة Postiz: `postiz` مع `temporal` مع `temporal-es` مع
`postgres` مع `redis` تقارب **1.05 GB مجتمعة**، أي سبعة أضعاف ما يستهلكه n8n.
معظمها في Elasticsearch وTemporal، وهما بنية تحتية لجدولة Postiz لا أكثر.

يعني أكبر مكسب ذاكرة متاح ليس في كتابة بديل n8n، بل في قرار بشأن حزمة Postiz.
هذا قرار منتج لا قرار هندسي، ويحتاج رأي فرحان.

## ما لم يُجمع بعد

- تفصيل أحجام `/vault` (الأمر لم يكتمل ضمن المهلة).
- قائمة الـ workflows الفعلية داخل n8n.
- أحجام قواعد البيانات.
- محتوى ملفات compose ومتغيرات البيئة.
- توكن Cloudflare والأنفاق المهيأة.

هذه مطلوبة قبل كتابة سكربت النسخ الاحتياطي، وهي الخطوة التالية مباشرة.
