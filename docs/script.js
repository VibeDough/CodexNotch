const observer = new IntersectionObserver(entries => {
  entries.forEach(entry => {
    if (entry.isIntersecting) {
      entry.target.classList.add('visible');
      observer.unobserve(entry.target);
    }
  });
}, { threshold: 0.12 });

document.querySelectorAll('.reveal').forEach(element => observer.observe(element));

const viewCount = document.querySelector('[data-view-count]');
if (viewCount) {
  fetch('/api/views', { cache: 'no-store' })
    .then(response => response.ok ? response.json() : Promise.reject())
    .then(({ views }) => {
      if (!Number.isFinite(views)) return;
      const label = viewCount.dataset.viewLabel;
      viewCount.textContent = `· ◉ ${new Intl.NumberFormat().format(views)} ${label}`;
      viewCount.hidden = false;
    })
    .catch(() => {});
}

document.querySelector('[data-copy]')?.addEventListener('click', async event => {
  const button = event.currentTarget;
  try {
    await navigator.clipboard.writeText(button.dataset.copy);
    button.textContent = '已复制';
    window.setTimeout(() => { button.textContent = '复制'; }, 1400);
  } catch {
    button.textContent = '请手动复制';
  }
});
