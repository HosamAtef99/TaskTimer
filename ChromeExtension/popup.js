const $ = (id) => document.getElementById(id);

async function render() {
  const s = await TT.session();
  $('out').hidden = !!s;
  $('in').hidden = !s;
  if (s) $('who').textContent = s.email || '';
}
$('runNow').addEventListener('click', async () => {
  $('runNow').disabled = true;
  $('runMsg').textContent = 'Checking Modhesh…';
  await chrome.storage.local.set({ attempts: {} });
  await chrome.runtime.sendMessage({ type: 'readNow' }).catch(() => {});
  $('runMsg').textContent = 'Done — your Modhesh tasks are in TaskTimer, and finished ones are being logged.';
  $('runNow').disabled = false;
});

$('signin').addEventListener('click', async () => {
  $('err').textContent = '';
  const email = $('email').value.trim().toLowerCase();
  const password = $('password').value;
  if (!email || !password) return;
  $('signin').disabled = true;
  try {
    await TT.signIn(email, password);
    chrome.runtime.sendMessage({ type: 'signedIn' }).catch(() => {});
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
