import fs from "fs";
const KEY = process.env.ONESIGNAL_REST_KEY, APP = process.env.ONESIGNAL_APP_ID;
if (!KEY || !APP) { console.log("ONESIGNAL_REST_KEY is missing"); process.exit(1); }
const msgs = [
  { t: "هيا بنا لجولة!", b: "خصمك ينتظرك على اللوحة. ابدأ جولة الآن." },
  { t: "مكافأتك اليومية بانتظارك", b: "لا تنسَ مكافأتك اليومية في Master Ludo." },
  { t: "صالة الألعاب مفتوحة", b: "إكس أو، أربعة في صف، والشطرنج، وغيرها." },
  { t: "هل تستطيع الفوز اليوم؟", b: "العب جولة سريعة وأثبت أنك الأذكى." },
  { t: "تحدٍّ جديد", b: "حاول كسر رقمك القياسي في إحدى ألعاب صالة الألعاب." },
  { t: "متجر الماس", b: "تفقّد قطع المتجر قبل أن تنفد." },
];
const m = msgs[Math.floor(Date.now() / 7200000) % msgs.length];
const res = await fetch("https://onesignal.com/api/v1/notifications", {
  method: "POST",
  headers: { "Content-Type": "application/json", Authorization: "Key " + KEY },
  body: JSON.stringify({ app_id: APP, included_segments: ["Subscribed Users"], headings: { ar: m.t, en: m.t }, contents: { ar: m.b, en: m.b }, url: "https://master-ludo-beta.netlify.app/" }),
});
console.log("OneSignal status", res.status, await res.text());
if (!res.ok) process.exit(1);
const data = JSON.parse(fs.readFileSync("notifications.json", "utf8"));
data.items = [{ title: m.t, text: m.b, at: Date.now() }].concat(data.items || []).slice(0, 30);
fs.writeFileSync("notifications.json", JSON.stringify(data, null, 2) + "\n");
