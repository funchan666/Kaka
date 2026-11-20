(() => {
  const Kaka = window.Kaka;
  const {get, element, button, message} = Kaka;
  const statusCopy = {
    apple: 'Continue in the App Store purchase sheet.',
    deferred: 'Waiting for Apple approval.',
    verifying: 'Verifying your purchase…',
    pending: 'Your purchase is waiting for confirmation.',
    complete: 'Purchase confirmed.',
    failed: 'The App Store could not complete the request.',
    cancelled: 'Cancelled.',
    restoring: 'Checking for purchases with Apple…',
    restored: 'Restore check finished.',
    wrongAccount: 'Sign in to the account that started this purchase to finish it.',
  };
  const updating = new Set(['apple', 'verifying', 'pending', 'restoring']);
  let generation = 0;
  let timer;
  let action;
  let checkoutBusy = false;

  function visible() {
    return get('commerce-panel').open && !get('crate').hidden && !document.hidden;
  }

  function send(operation, payload = {}) {
    return Kaka.service.request('commerce.' + operation, payload);
  }

  function status(state) {
    message(get('commerce-status'), statusCopy[state] ?? '');
    checkoutBusy = ['apple', 'verifying', 'restoring'].includes(state);
    controls();
  }

  function controls() {
    get('commerce-restore').disabled = Boolean(action) || checkoutBusy;
    get('commerce-packs').querySelectorAll('button').forEach((control) => {
      control.disabled = Boolean(action) || checkoutBusy || control.dataset.available !== 'true';
    });
    const claim = get('commerce-claim');
    if (claim) claim.disabled = Boolean(action) || claim.dataset.available !== 'true';
  }

  function setWallet(wallet) {
    if (typeof wallet?.balance !== 'string') throw new Error('Invalid wallet response');
    get('commerce-wallet').textContent = wallet.balance + ' diamonds';
    status(wallet.purchaseState);
    return wallet.purchaseState;
  }

  function poll(epoch, remaining = 9) {
    clearTimeout(timer);
    if (!visible() || remaining === 0) return;
    timer = setTimeout(async () => {
      if (epoch !== generation || !visible()) return;
      if (action) {
        poll(epoch, remaining - 1);
        return;
      }
      try {
        const wallet = await send('wallet');
        if (epoch !== generation || !visible()) return;
        const state = setWallet(wallet);
        if (updating.has(state)) poll(epoch, remaining - 1);
      } catch {
        if (epoch === generation && visible()) poll(epoch, remaining - 1);
      }
    }, 5000);
  }

  function renderPacks(payload) {
    const area = get('commerce-packs');
    const packs = Array.isArray(payload?.packs) ? payload.packs : [];
    if (packs.length === 0) {
      const copy = payload?.missingAppleProducts > 0
        ? 'Recharge packs aren’t available for this app in the App Store.'
        : 'No recharge packs are available.';
      area.replaceChildren(element('p', 'caption', copy));
      return;
    }
    area.replaceChildren(...packs.map((pack) => {
      const row = element('div', 'crate-list-row');
      const title = element('div', 'track-copy');
      title.append(element('strong', '', pack.diamonds + ' diamonds'));
      if (pack.bonus !== '0') title.append(element('span', 'caption', '+' + pack.bonus + ' bonus'));
      if (pack.firstBonus !== '0') title.append(element('span', 'caption', '+' + pack.firstBonus + ' on your first purchase'));
      const purchase = button(pack.price, () => perform('purchase', {productID: pack.id}));
      purchase.dataset.available = String(pack.available);
      purchase.setAttribute('aria-label', 'Buy ' + pack.diamonds + ' diamonds for ' + pack.price);
      row.append(title, purchase);
      return row;
    }));
    if (payload.missingAppleProducts > 0) area.append(element('p', 'caption', 'Some packs are unavailable in the App Store.'));
    controls();
  }

  function permitted(reward) {
    return [true, 1, '1', 'true'].includes(reward);
  }

  function renderRewards(value) {
    const text = get('commerce-reward');
    const claim = get('commerce-claim');
    const available = permitted(value?.castPermit) && !permitted(value?.orbitBound);
    if (text) {
      if (permitted(value?.dawnMarked)) message(text, 'Checked in today');
      else if (permitted(value?.orbitBound)) message(text, 'Daily rewards unlock at Level 1.');
      else if (available) message(text, 'Your daily reward is available.');
      else message(text, 'No reward is available right now.');
    }
    if (claim) {
      claim.hidden = !available;
      claim.dataset.available = String(available);
      controls();
    }
  }

  async function refresh() {
    clearTimeout(timer);
    const epoch = ++generation;
    const wallet = get('commerce-wallet');
    wallet.textContent = 'Loading wallet…';
    const tasks = [
      ['wallet', (response) => {
        if (updating.has(setWallet(response))) poll(epoch);
      }, () => { wallet.textContent = 'Wallet unavailable.'; }],
      ['catalog', renderPacks, () => {
        get('commerce-packs').replaceChildren(element('p', 'caption', 'Recharge packs are unavailable.'));
      }],
    ];
    if (get('commerce-reward')) tasks.push(['rewards', renderRewards, () => {
      message(get('commerce-reward'), 'Daily rewards unavailable.');
      const claim = get('commerce-claim');
      if (claim) {
        claim.hidden = true;
        claim.dataset.available = 'false';
      }
      controls();
    }]);
    const level = get('commerce-level');
    if (level) tasks.push(['level', (value) => {
      message(level, value?.tierTitle || 'Level unavailable.');
    }, () => { message(level, 'Level unavailable.'); }]);
    await Promise.all(tasks.map(async ([operation, render, fail]) => {
      try {
        const answer = await send(operation);
        if (generation === epoch && visible()) render(answer);
      } catch {
        if (generation === epoch && visible()) fail();
      }
    }));
  }

  async function perform(operation, data) {
    if (action || !visible()) return;
    const epoch = generation;
    const label = {purchase: 'Starting purchase…', restore: 'Checking purchases…', claimReward: 'Claiming reward…'};
    const error = {
      purchase: 'Couldn’t start the purchase. Check your wallet before trying again.',
      restore: 'Couldn’t check for purchases.',
      claimReward: 'Couldn’t confirm the reward. Check your balance before trying again.',
    };
    action = Symbol();
    const request = action;
    controls();
    message(get('commerce-status'), label[operation]);
    try {
      const response = await send(operation, data);
      if (generation !== epoch || !visible()) return;
      if (operation === 'claimReward') {
        await refresh();
        if (action === request && visible()) message(get('commerce-status'), 'Reward claimed.');
      } else {
        status(response.purchaseState);
        poll(epoch);
      }
    } catch {
      if (generation === epoch && visible()) message(get('commerce-status'), error[operation]);
    } finally {
      if (action === request) {
        action = undefined;
        controls();
      }
    }
  }

  function reset() {
    generation += 1;
    clearTimeout(timer);
    action = undefined;
    checkoutBusy = false;
    get('commerce-panel').open = false;
    get('commerce-wallet').textContent = '';
    get('commerce-packs').replaceChildren();
    message(get('commerce-status'));
    for (const id of ['commerce-reward', 'commerce-level']) {
      const text = get(id);
      if (text) message(text);
    }
    const claim = get('commerce-claim');
    if (claim) {
      claim.hidden = true;
      claim.dataset.available = 'false';
    }
    controls();
  }

  function init() {
    get('commerce-panel').addEventListener('toggle', () => {
      if (visible()) refresh();
      else clearTimeout(timer);
    });
    get('commerce-restore').addEventListener('click', () => perform('restore'));
    get('commerce-claim')?.addEventListener('click', () => perform('claimReward'));
    document.addEventListener('visibilitychange', () => {
      if (visible() && !action) refresh();
      else clearTimeout(timer);
    });
    window.addEventListener('hashchange', () => {
      clearTimeout(timer);
      if (location.hash === '#crate' && get('commerce-panel').open && !document.hidden && !action) refresh();
    });
  }

  Kaka.commerce = {init, reset};
})();
