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

## تحديث 2026-08-09 — الجرد بعد ستة أيام، ومقارنة بجدول الخدمات

المصدر: `C:\hajime-backups\carbonflow-image-20260809-113045\docker-ps.txt`،
لقطة قراءة فقط أُخذت بتاريخ 2026-08-09 الساعة 11:30 والجهاز شغّال، مقارنة مع
هذا الملف ومع `hajime-sys/src/service.rs` و`hajime-web/sites.conf` كما هما في
هذا الفرع.

**تصحيح عدد الحاويات.** الجلسة التي كتبت هذا الطلب افترضت 19 حاوية. هذا الملف
نفسه، بتاريخ 2026-08-03، يسجّل **26** لا 19 (وصحّح رقماً أقدم كان 17). قائمة
اليوم تطابق هذه الـ26 اسماً باسم — لا حاوية غابت ولا حاوية زادت منذ الجرد.

### ما تغيّرت حالته منذ 2026-08-03

سبع حاويات من الـ26 صارت `Exited`، كلها منذ خمسة أيام تقريباً من لحظة الالتقاط
— أي في اليوم التالي مباشرة لكتابة هذا الجرد أو نحوه:

| الحاوية | الحالة | رمز الخروج |
|---|---|---|
| postiz | Exited، منذ 5 أيام | 137 (SIGKILL) |
| postiz-temporal | Exited، منذ 5 أيام | 137 (SIGKILL) |
| postiz-temporal-es | Exited، منذ 5 أيام | 143 (SIGTERM) |
| postiz-postgres | Exited، منذ 5 أيام | 0 (خروج نظيف) |
| postiz-redis | Exited، منذ 5 أيام | 0 (خروج نظيف) |
| carbonflow-release-api | Exited، منذ 5 أيام | 137 (SIGKILL) |
| carbonflow-telemetry-api | Exited، منذ 5 أيام | 137 (SIGKILL) |

حزمة Postiz الخمس سقطت معاً، وثلاث منها برمز 137 أي قُتلت لا أُوقفت بأمر نظيف.
هذا الملف نفسه حذّر في القسم أعلاه من أن السواب المستخدم (4.3 GB) يعني أن
الجهاز تجاوز ذاكرته الفعلية سابقاً؛ سقوط أثقل حزمة على الجهاز (postiz +
temporal + temporal-es + postgres + redis، ~1.05 GB مجتمعة حسب القياس أعلاه)
بهذا الشكل متوافق مع حدث ضغط ذاكرة حقيقي، لا مع إيقاف مقصود. `release-api`
و`telemetry-api` كانتا متوقفتين أصلاً بلا فائدة (انظر أدناه)، فسقوطهما لا يغيّر
شيئاً عملياً.

### أين استقرت كل حاوية في النظام الجديد

مصادر هذا القسم: `decisions.md` (قرار 2026-08-03 «النطاق النهائي للبرامج
المخصصة»)، و`TOOLING.md` (جدول الاستبدال)، و`hajime-web/sites.conf` و
`hajime-web/README.md` (قُرئا اليوم أيضاً من الخادم القديم).

| الحاوية القديمة | الوجهة في hajime | الحالة |
|---|---|---|
| carbonflow-n8n | `hajime_workflow` | مبني ومُتحقَّق منه بالتصدير الحقيقي (انظر القسم الأول من هذا التقرير) |
| carbonflow-waha | `hajime_wa` + `hajime_wa_bridge` | مبني، تحقّق فعلي على FreeBSD مسجَّل في `decisions.md` 2026-08-04 |
| carbonflow-ollama | `llamacpp` (+ `hajime_ai` كبوابة بصيغة OpenAI) | قرار مسجَّل، مبني |
| carbonflow-npm | `caddy` + `hajime-web/sites.conf` | قرار مسجَّل صراحة في `TOOLING.md`: «Caddy يغني عنه» |
| carbonflow-npm-db | لا بديل — وهذا صحيح لا نقص | قاعدة بيانات NPM نفسه، تصير بلا معنى بمجرد إسقاط NPM |
| carbonflow-litecart-db | `mysql` (وصفها في الجدول حرفياً «MariaDB, the shop database») | قرار مسجَّل، مبني |
| carbonflow-litecart | jail الويب + php-fpm + `hajime-web` | القرار موجود (jail الويب «مواقع عامة ومتجر PHP» منذ البداية)، لكن صف `shop.carbonflows.store` مكتوب **معطَّلاً** في `sites.conf` لأن جذر مستندات المتجر على القرص الجديد لم يُقرَّر بعد |
| carbonflow-control-panel | `hajime_console` | قرار مسجَّل صراحة: «يُعاد بناؤه بـ Rust ليكون لوحة تحكم النظام لا لوحة موقع» |
| carbonflow-cloudflared | `cloudflared` | مطابقة مباشرة |
| carbonflow-cloakbrowser | `hajime-fetch` | قرار مسجَّل في `TOOLING.md`؛ مكتبة داخل العملية لا خدمة مستقلة، فلا يُنتظر لها سطر في `service.rs` |
| carbonflow-portfolio | موقع ثابت عبر `hajime-web` | النوع مؤكَّد (`static`، دليله رأس CSP في nginx الحاوية نفسها) لكن **الهدف غير مؤكَّد**: لا اصطلاح بعد لمكان محتوى موقع ثابت مهاجَر على FreeBSD، فالصف غير مكتوب أصلاً في `sites.conf` |
| carbonflow-release-api | **أُسقطت** | قرار مسجَّل: صفر طلب في 30 يوماً |
| carbonflow-telemetry-api | **أُسقطت** | قرار مسجَّل: صفر طلب في 30 يوماً، و`/vault/products` فارغ |

### بلا وجهة وبلا قرار مسجَّل

| الحاوية | الحالة |
|---|---|
| carbonflow-uptime-kuma | `ARCHITECTURE.md` الأصلي أراد إبقاءه (أو Prometheus)، و`TOOLING.md` يسجّل أنه لا يدعم FreeBSD رسمياً، وينتهي الأمر هناك. لا سطر في `service.rs`، ولا قرار إسقاط مسجَّل كالذي صدر بحق `release-api`. |
| carbonflow-crowdsec | نفس النمط: `ARCHITECTURE.md` أراد إبقاءه، و`TOOLING.md` يسجّل أن المنفذ في شجرة FreeBSD موجود لكن «يحتاج تحققاً عملياً» — ولم يُتحقَّق ولم يُقرَّر. |
| carbonflow-telegram-openai-bot | لا ذكر له في أي مكان: لا في قرار «النطاق النهائي للبرامج المخصصة» (الذي عدّد `release-api` و`telemetry-api` و`control-panel` و`fatmalens` و`qood` تحديداً ولم يذكره)، ولا في جدول `TOOLING.md`، ولا صف في `sites.conf`. الأثر الوحيد له اسم متغيّر بيئة (`OPENWA_BASE_URL`) داخل حاويتين أخريين يشير إلى WAHA. |
| postiz + postiz-postgres + postiz-redis + postiz-temporal + postiz-temporal-es | قرار منتج معلّق بيد فرحان منذ 2026-08-03 كما سجّله هذا الملف أعلاه، ولا يزال معلَّقاً اليوم. والحزمة الآن متوقفة فعلياً (انظر القسم السابق) بعد أن كانت المستهلك الأكبر للذاكرة على الجهاز. |
| fatmalens-album + fatmalens-tunnel + qood-caddy + qood-orders | هذه لها قرار مسجَّل، لكنه تأجيل لا إسقاط: «تُسحب كمشاريع مستقلة وتُعاد بعد تثبيت النظام». `sites.conf` يحمل بالفعل صفوفاً حيّة لثلاثة نطاقات qood وواحد لـfatmalens جاهزة ليوم عودتها، رغم أن لا شيء سيستمع على تلك المنافذ حتى تُبنى تلك المشاريع من جديد. |

### تضاربان في المنافذ لم يفحصهما أحد بعد

`hajime-web/sites.conf` بُني من قراءة الخادم القديم وحده، و`hajime-sys/src/service.rs`
بُني من احتياج Hajime لنفسه وحده. لا شيء قارن الاثنين ببعضهما حتى الآن، والمقارنة
تكشف تضاربين حقيقيين في أرقام المنافذ:

- **`status.carbonflows.store`** في `sites.conf` صف حيّ (غير معطَّل) يمرّر إلى
  `127.0.0.1:3001`، وهو منفذ uptime-kuma على الخادم القديم (مؤكَّد بمتغيرات
  `UPTIME_KUMA_BASE_URL`/`UPTIME_KUMA_STATUS_URL`). لكن `service.rs` يخصّص
  المنفذ **3001** نفسه لـ`hajime_wa_bridge` («WhatsApp protocol bridge»). لو
  عمل الاثنان معاً، سيصل زائر `status.carbonflows.store` إلى جسر الواتساب
  بصمت، لا إلى أي صفحة حالة — وأصلاً لا بديل مبني لـuptime-kuma (انظر أعلاه).
- **`byfatmalens.space`** في `sites.conf` صف حيّ يمرّر إلى `127.0.0.1:3000`،
  ونفس المنفذ **3000** مخصَّص في `service.rs` لـ`hajime_wa` («WhatsApp
  gateway»). التضارب كامن اليوم لأن fatmalens مؤجَّل (انظر أعلاه)، لكنه سيصطدم
  فعلياً في اليوم الذي يعود فيه.

### ما في `service.rs` ولا مقابل حقيقي له اليوم

`hajime_console` و`hajime_ai` و`llamacpp` كلها قرارات مسجَّلة (تعيد بناء
control-panel، وتضع بوابة بصيغة OpenAI أمام الاستدلال، وتستبدل Ollama —
بالترتيب)، فليست فراغاً غير مبرَّر.

الأقرب إلى فراغ حقيقي: **`postgresql`** و**`redis`**، وكلاهما **Essential** في
الجدول (لا يُوقَفان تلقائياً، وفشلهما يمنع إعلان الجاهزية حسب توثيق `Tier` في
نفس الملف). وصف `postgresql` في الجدول حرفياً «the database behind the
workflow store». لكن `hajime-workflow/src/store.rs` — الذي قرأته هذه الجلسة
كاملاً للتحقق من مطلب آخر — مخزن في الذاكرة (`RwLock<HashMap<...>>`) يُحمَّل من
ملف JSON لتصدير n8n، ولا يمسّ قاعدة بيانات على الإطلاق. بحث في شجرة المصدر
كلها عن أي استخدام فعلي لعميل postgres أو redis (`sqlx`, `diesel`,
`tokio_postgres`, أو استدعاء مباشر لـredis) لم يجد شيئاً خارج اسم الخدمة في
`service.rs` نفسه وجداول `hajime-model`/`hajime-sys` التي تتحدّث *عن* الخدمة
بالاسم لا تتصل بها. اختبار `databases_start_before_the_things_that_use_them`
في `service.rs` يفترض صراحةً أن `hajime_workflow` يعتمد على `postgresql`
(`pos("postgresql") < pos("hajime_workflow")`)، وهذا الافتراض لا يطابق ما
يفعله `store.rs` فعلياً اليوم.

المقابل الوحيد المعقول للاثنين على الخادم القديم هو `postiz-postgres` و
`postiz-redis` تحديداً — وهما داخل نفس حزمة Postiz المعلَّقة قرارها والمتوقفة
فعلياً الآن. إما أن يُوجَد لهما عمل حقيقي في هذا النظام، أو يُعاد تصنيفهما
Optional حتى يُقرَّر مصير Postiz، بدل أن يبقيا Essential يمنعان إعلان الجاهزية
لخدمة لا شيء يستهلكها.
