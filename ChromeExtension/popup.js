const $ = (id) => document.getElementById(id);

async function render() {
  const s = await TT.session();
  $('out').hidden = !!s;
  $('in').hidden = !s;
  if (s) $('who').textContent = s.email || '';
  const { autoSubmit, autoLink } = await chrome.storage.local.get(['autoSubmit', 'autoLink']);
  $('autoSubmit').checked = autoSubmit !== false;
  $('autoLink').checked = autoLink !== false;
}

$('autoSubmit').addEventListener('change', (e) => chrome.storage.local.set({ autoSubmit: e.target.checked }));
$('autoLink').addEventListener('change', (e) => chrome.storage.local.set({ autoLink: e.target.checked }));
$('runNow').addEventListener('click', async () => {
  $('runMsg').textContent = 'Checking…';
  await chrome.storage.local.set({ attempts: {} });
  await chrome.runtime.sendMessage({ type: 'tickNow' }).catch(() => {});
  $('runMsg').textContent = 'Done — finished tasks are being logged.';
});

$('signin').addEventListener('click', async () => {
  $('err').textContent = '';
  const email = $('email').value.trim().toLowerCase();
  const password = $('password').value;
  if (!email || !password) return;
  $('signin').disabled = true;
  try {
    await TT.signIn(email, password);
    $('password').value = '';
    await render();
  } catch (e) {
    $('err').textContent = e.message;
  } finally {
    $('signin').disabled = false;
  }
});

$('password').addEventListener('keydown', (e) => { if (e.key === 'Enter') $('signin').click(); });

$('signout').addEventListener('click', async () => {
  await TT.signOut();
  await render();
});

render();
