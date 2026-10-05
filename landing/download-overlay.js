// После нажатия «Скачать» показывает, где искать загрузку: стрелка
// в правый верхний угол, где значок загрузок во всех основных браузерах.
(function () {
  // Ushi только для Mac: на телефонах и планшетах экран не нужен.
  var isPhone = /iPhone|iPad|iPod|Android/i.test(navigator.userAgent) ||
    (/Macintosh/.test(navigator.userAgent) && navigator.maxTouchPoints > 1);
  if (isPhone) return;

  var css =
    '.dl-overlay{position:fixed;inset:0;width:100%;height:100%;max-width:none;max-height:none;margin:0;padding:24px;border:0;' +
      'background:transparent;color:#fff;font-family:"Onest",-apple-system,BlinkMacSystemFont,sans-serif;overflow:hidden}' +
    '.dl-overlay[open]{display:flex;align-items:center;justify-content:center}' +
    '.dl-overlay::backdrop{background:rgba(10,12,16,.78);-webkit-backdrop-filter:blur(6px);backdrop-filter:blur(6px)}' +
    '.dl-overlay[open]{animation:dl-in .25s ease}' +
    '@keyframes dl-in{from{opacity:0}to{opacity:1}}' +
    '.dl-body{display:flex;flex-direction:column;align-items:center;text-align:center;max-width:520px}' +
    '.dl-icon{position:relative;width:120px;height:120px;margin-bottom:36px}' +
    '.dl-icon svg.dl-logo{width:100%;height:100%;border-radius:27px;box-shadow:0 12px 40px rgba(0,0,0,.35)}' +
    '.dl-badge{position:absolute;top:-12px;right:-12px;width:40px;height:40px;border-radius:50%;background:#2f6fe4;' +
      'display:flex;align-items:center;justify-content:center;box-shadow:0 4px 12px rgba(0,0,0,.3);animation:dl-bob 1.6s ease-in-out infinite}' +
    '@keyframes dl-bob{0%,100%{transform:translateY(0)}50%{transform:translateY(3px)}}' +
    '.dl-title{font-family:"Unbounded",sans-serif;font-weight:400;font-size:34px;line-height:1.25;letter-spacing:-.02em;text-wrap:balance;margin:0}' +
    '.dl-hint{margin:24px 0 0;padding:12px 20px;border-radius:14px;background:rgba(255,255,255,.12);font-size:16px;line-height:1.5}' +
    '.dl-link{margin-top:28px;color:rgba(255,255,255,.75);font-size:15px;text-underline-offset:4px}' +
    '.dl-link:hover{color:#fff}' +
    '.dl-close{position:absolute;top:20px;left:20px;width:44px;height:44px;border:0;border-radius:50%;background:rgba(255,255,255,.12);' +
      'color:#fff;cursor:pointer;display:flex;align-items:center;justify-content:center}' +
    '.dl-close:hover{background:rgba(255,255,255,.2)}' +
    '.dl-close:focus-visible,.dl-link:focus-visible{outline:2px solid #fff;outline-offset:3px}' +
    '.dl-arrow{position:absolute;top:16px;right:56px;width:min(30vw,300px);height:auto;pointer-events:none}' +
    '@media (max-width:640px){.dl-title{font-size:26px}.dl-arrow{width:120px;right:24px}}' +
    '@media (prefers-reduced-motion:reduce){.dl-overlay[open],.dl-badge{animation:none}}';

  var logo =
    '<svg class="dl-logo" viewBox="0 0 928 928" xmlns="http://www.w3.org/2000/svg" aria-hidden="true">' +
      '<defs><linearGradient id="dlLogoBg" x1="464" y1="0" x2="464" y2="928" gradientUnits="userSpaceOnUse">' +
      '<stop stop-color="#222E3D"/><stop offset="1" stop-color="#171C24"/></linearGradient></defs>' +
      '<rect width="928" height="928" fill="url(#dlLogoBg)"/>' +
      '<path d="M524.439 780.729C549.552 780.729 570.735 773.729 588.244 759.885C606.562 745.27 620.712 725.41 630.613 700.114L630.636 700.06C641.169 674.116 646.484 644.657 646.484 611.612V102H669V611.612C669 657.123 660.319 696.203 642.735 728.666L642.726 728.684L642.716 728.701C625.161 760.463 600.727 784.835 569.466 801.717L569.45 801.725L569.436 801.733C538.847 817.954 503.812 826 464.452 826C425.09 826 389.754 817.954 358.552 801.752L358.519 801.734L358.486 801.717C327.239 784.843 302.504 760.491 284.318 728.763L284.29 728.715L284.265 728.666C266.681 696.203 258 657.123 258 611.612V307.676H403.345V611.612C403.345 660.307 413.67 700.851 434.046 733.493C454.078 764.962 483.971 780.729 524.439 780.729Z" fill="white"/>' +
      '<path d="M403.662 174.63C403.662 214.762 371.035 247.26 330.831 247.26C290.627 247.26 258 214.762 258 174.63C258 134.498 290.627 102 330.831 102C371.035 102 403.662 134.498 403.662 174.63Z" fill="white"/>' +
    '</svg>';

  var html =
    '<button class="dl-close" type="button" aria-label="Закрыть">' +
      '<svg width="16" height="16" viewBox="0 0 16 16" aria-hidden="true"><path d="M2 2l12 12M14 2L2 14" stroke="currentColor" stroke-width="2" stroke-linecap="round"/></svg>' +
    '</button>' +
    '<svg class="dl-arrow" viewBox="0 0 300 260" fill="none" aria-hidden="true">' +
      '<path d="M20 250 C 150 250, 255 180, 268 22" stroke="#fff" stroke-width="4" stroke-linecap="round"/>' +
      '<path d="M246 44 L268 18 L286 48" stroke="#fff" stroke-width="4" stroke-linecap="round" stroke-linejoin="round"/>' +
    '</svg>' +
    '<div class="dl-body">' +
      '<div class="dl-icon">' + logo +
        '<span class="dl-badge"><svg width="18" height="18" viewBox="0 0 18 18" aria-hidden="true"><path d="M9 2v12M3.5 9 9 14.5 14.5 9" stroke="#fff" stroke-width="2.2" fill="none" stroke-linecap="round" stroke-linejoin="round"/></svg></span>' +
      '</div>' +
      '<h2 class="dl-title" id="dl-title">Загрузка Ushi началась</h2>' +
      '<p class="dl-hint">Когда файл скачается, откройте <b>ushi.dmg</b><br>в загрузках браузера — справа вверху</p>' +
      '<a class="dl-link" href="/#install">Как установить</a>' +
    '</div>';

  var dialog;
  function build() {
    var style = document.createElement('style');
    style.textContent = css;
    document.head.appendChild(style);
    dialog = document.createElement('dialog');
    dialog.className = 'dl-overlay';
    dialog.setAttribute('aria-labelledby', 'dl-title');
    dialog.innerHTML = html;
    document.body.appendChild(dialog);
    dialog.addEventListener('click', function (event) {
      var t = event.target;
      // Ссылка на инструкцию тоже закрывает экран, а браузер прокручивает к шагам.
      if (t === dialog || t.closest('.dl-close') || t.closest('.dl-link')) dialog.close();
    });
  }

  // Делегирование: на главной кнопка рисуется скриптом уже после загрузки.
  document.addEventListener('click', function (event) {
    var link = event.target.closest && event.target.closest('a[href$="ushi.dmg"]');
    if (!link || event.metaKey || event.ctrlKey || event.shiftKey || event.altKey) return;
    if (!dialog) build();
    // Скачивание идёт своим ходом; экран показываем сразу после клика.
    setTimeout(function () { if (!dialog.open) dialog.showModal(); }, 0);
  });
})();
