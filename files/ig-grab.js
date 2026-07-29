// ig-grab.js — PROVEN click-to-pick bookmarklet (the "IG Grab" image tool).
//
// Runs ON instagram.com, in the user's logged-in session. Click the bookmarklet,
// then click the exact image/video you want — it reads the highest-res source and
// downloads it (falls back to opening a tab if the CDN blocks the cross-origin fetch).
//
// WORKS FOR: images, including picking a specific carousel slide (you point at it).
// DOES NOT WORK FOR: blob videos (IG Reels/most video) — alerts the user to use yt-dlp.
//
// This is the reference for the "images stay as click-to-pick" option. If the user
// chooses to fold images into the paste-a-link flow instead, gallery-dl replaces this.
//
// To install as a bookmark: paste the whole thing (including the `javascript:` prefix
// version) into a bookmark's URL field. Minified single-line version is what actually
// goes in the bookmark; this is the readable source.

javascript:(function(){
  if(window.__igGrab)return;window.__igGrab=1;
  var b=document.createElement('div');
  b.textContent='IG Grab — click the image or video you want (Esc to cancel)';
  b.style.cssText='position:fixed;top:12px;left:50%;transform:translateX(-50%);z-index:2147483647;background:#000;color:#fff;padding:10px 16px;border-radius:8px;font:14px sans-serif';
  document.body.appendChild(b);
  function done(){window.__igGrab=0;b.remove();document.removeEventListener('click',h,true);document.removeEventListener('keydown',k,true);}
  function k(e){if(e.key==='Escape')done();}
  function save(url,ext){
    var name='instagram_'+Date.now()+'.'+(ext||'jpg');
    fetch(url).then(function(r){return r.blob();}).then(function(blob){
      var u=URL.createObjectURL(blob),a=document.createElement('a');
      a.href=u;a.download=name;document.body.appendChild(a);a.click();a.remove();
      setTimeout(function(){URL.revokeObjectURL(u);},1000);
    }).catch(function(){window.open(url,'_blank');});
  }
  function h(e){
    e.preventDefault();e.stopPropagation();
    var media=null,stack=document.elementsFromPoint(e.clientX,e.clientY);
    for(var i=0;i<stack.length;i++){if(stack[i].tagName==='IMG'||stack[i].tagName==='VIDEO'){media=stack[i];break;}}
    if(!media){var n=e.target.closest('li,div');if(n)media=n.querySelector('video,img');}
    if(!media){alert('No media there — click directly on it');return;}
    if(media.tagName==='VIDEO'){
      var s=media.querySelector('source');
      var vurl=(s&&s.src)||media.currentSrc||media.src;
      if(!vurl||vurl.indexOf('blob:')===0){alert('This video is a streaming blob — use yt-dlp for this one.');done();return;}
      save(vurl,'mp4');done();return;
    }
    var url=media.currentSrc||media.src;
    if(media.srcset){url=media.srcset.split(',').map(function(x){return x.trim().split(' ');}).sort(function(a,b){return parseInt(b[1])-parseInt(a[1]);})[0][0];}
    save(url,'jpg');done();
  }
  document.addEventListener('click',h,true);
  document.addEventListener('keydown',k,true);
})();
