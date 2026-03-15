const askBtn = document.getElementById("askBtn");
const questionEl = document.getElementById("question");
const answerEl = document.getElementById("answer");
const citationsEl = document.getElementById("citations");
const charCountEl = document.getElementById("charCount");
const citationCountEl = document.getElementById("citationCount");
const responseMetaEl = document.getElementById("responseMeta");
const statusBadgeEl = document.getElementById("statusBadge");
const quickPromptsEl = document.getElementById("quickPrompts");

function setStatus(text, busy = false) {
  statusBadgeEl.textContent = text;
  statusBadgeEl.classList.toggle("busy", busy);
}

function updateCharCount() {
  charCountEl.textContent = `${questionEl.value.length} chars`;
}

function showError(message) {
  answerEl.textContent = message;
  answerEl.classList.add("error");
}

function formatTime() {
  const now = new Date();
  return `${now.getHours().toString().padStart(2, "0")}:${now
    .getMinutes()
    .toString()
    .padStart(2, "0")}`;
}

function renderCitations(cites) {
  if (!Array.isArray(cites) || cites.length === 0) {
    citationsEl.innerHTML = "<li class='empty'>引用はありません。</li>";
    citationCountEl.textContent = "0 sources";
    return;
  }

  citationCountEl.textContent = `${cites.length} sources`;
  citationsEl.innerHTML = "";
  for (const [idx, c] of cites.entries()) {
    const li = document.createElement("li");
    li.className = "cite";
    const source = c.source || "unknown";
    const section = c.section ? ` / ${c.section}` : "";
    li.innerHTML = `<span class="meta">#${idx + 1}</span>${source}${section}`;
    citationsEl.appendChild(li);
  }
}

async function submitQuestion() {
  const question = questionEl.value.trim();
  answerEl.classList.remove("error");

  if (!question) {
    answerEl.textContent = "質問を入力してください。";
    return;
  }

  askBtn.disabled = true;
  answerEl.textContent = "問い合わせ中...";
  answerEl.classList.add("loading");
  citationsEl.innerHTML = "";
  citationCountEl.textContent = "--";
  responseMetaEl.textContent = "requesting...";
  setStatus("Thinking", true);

  try {
    const resp = await fetch("/ask", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ question }),
    });

    if (!resp.ok) {
      let detail = `HTTP ${resp.status}`;
      try {
        const errData = await resp.json();
        if (errData && errData.detail) {
          detail = errData.detail;
        }
      } catch (_) {
      }
      throw new Error(detail);
    }

    const data = await resp.json();
    answerEl.textContent = data.answer || "(回答なし)";
    renderCitations(data.citations);
    responseMetaEl.textContent = `updated ${formatTime()}`;
    setStatus("Ready", false);
  } catch (err) {
    showError(`エラー: ${err.message}`);
    renderCitations([]);
    responseMetaEl.textContent = `failed ${formatTime()}`;
    setStatus("Error", false);
  } finally {
    answerEl.classList.remove("loading");
    askBtn.disabled = false;
  }
}

askBtn.addEventListener("click", submitQuestion);
questionEl.addEventListener("input", updateCharCount);
questionEl.addEventListener("keydown", (event) => {
  if (event.key === "Enter" && (event.ctrlKey || event.metaKey)) {
    event.preventDefault();
    submitQuestion();
  }
});

quickPromptsEl.addEventListener("click", (event) => {
  const target = event.target;
  if (!(target instanceof HTMLElement)) {
    return;
  }
  if (!target.classList.contains("chip")) {
    return;
  }
  const prompt = target.dataset.prompt;
  if (!prompt) {
    return;
  }
  questionEl.value = prompt;
  updateCharCount();
  questionEl.focus();
});

updateCharCount();
setStatus("Ready", false);
renderCitations([]);
