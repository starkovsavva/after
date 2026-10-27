//! Import basic UTF-8 Anki text decks without running HTML or reading media.
//! Preview is read-only; an import validates the entire file before creating a
//! private standalone deck which reuses the existing FSRS review storage.
mod workspace;
mod operations;
use anyhow::{bail,ensure,Context,Result};
use chrono::Utc;
use serde_json::{json,Value};
use sha2::{Digest,Sha256};
use std::collections::HashSet;
use std::fs::{self,DirBuilder,OpenOptions};
use std::io::{Read,Write};
use std::os::unix::fs::{DirBuilderExt,OpenOptionsExt};
use std::path::Path;
use uuid::Uuid;
const MAX_FILE:u64=10*1_048_576;
const MAX_CARDS:usize=10_000;
const MAX_FIELD:usize=200_000;

struct Parsed { cards:Vec<Value>,warnings:Vec<String>,skipped:usize }
fn delimiter(value:&str)->Result<char> {
    match value.trim().to_lowercase().as_str() {
        "tab"|"tabs"|"\\t"=>Ok('\t'),"comma"|","=>Ok(','),"semicolon"|";"=>Ok(';'),"pipe"|"|"=>Ok('|'),"colon"|":"=>Ok(':'),
        _ if value=="\t"=>Ok('\t'),_=>bail!("Разделитель должен быть tab, comma, semicolon или pipe"),
    }
}
fn guess_delimiter(text:&str)->char {
    let mut counts=[0;3]; let mut quoted=false; let mut chars=text.chars().peekable();
    while let Some(c)=chars.next() {
        if c=='"' { if quoted && chars.peek()==Some(&'"') { chars.next(); } else { quoted=!quoted; } }
        if !quoted { match c { '\t'=>counts[0]+=1,','=>counts[1]+=1,';'=>counts[2]+=1,'\n'|'\r'=>break,_=>{} } }
    }
    if counts[0]>0 {'\t'} else if counts[2]>counts[1] {';'} else if counts[1]>0 {','} else {'\t'}
}
/// RFC-4180 quoting with configurable one-character separator. Quoted fields
/// retain line breaks and doubled quotes; malformed quoting fails explicitly.
fn rows(text:&str,separator:char)->Result<Vec<Vec<String>>> {
    let mut output=Vec::new(); let mut row=Vec::new(); let mut field=String::new();
    let mut chars=text.chars().peekable(); let mut quoted=false; let mut closed_quote=false;
    while let Some(c)=chars.next() {
        if quoted {
            if c=='"' {
                if chars.peek()==Some(&'"') { chars.next(); field.push('"'); }
                else { quoted=false; closed_quote=true; }
            } else { field.push(c); }
        } else if c==separator {
            row.push(std::mem::take(&mut field)); closed_quote=false;
        } else if c=='\n' || c=='\r' {
            if c=='\r' && chars.peek()==Some(&'\n') { chars.next(); }
            row.push(std::mem::take(&mut field)); closed_quote=false;
            if row.iter().any(|cell|!cell.trim().is_empty()) { output.push(std::mem::take(&mut row)); } else { row.clear(); }
            ensure!(output.len()<=MAX_CARDS+1,"В одном файле должно быть не больше 10 000 карточек");
        } else if c=='"' && field.is_empty() && !closed_quote { quoted=true; }
        else if closed_quote && c.is_whitespace() { /* export writers sometimes pad after closing quote */ }
        else { ensure!(!closed_quote && c!='"',"Некорректные кавычки в CSV/TSV. Проверьте экспорт файла."); field.push(c); }
        ensure!(field.len()<=MAX_FIELD,"Поле карточки слишком длинное");
        ensure!(row.len()<=64,"Слишком много столбцов в файле карточек");
    }
    ensure!(!quoted,"В CSV/TSV не закрыта кавычка");
    row.push(field); if row.iter().any(|cell|!cell.trim().is_empty()) { output.push(row); }
    ensure!(output.len()<=MAX_CARDS+1,"В одном файле должно быть не больше 10 000 карточек");
    Ok(output)
}
fn entity(value:&str)->Option<String> {
    match value {
        "amp"=>Some("&".into()),"lt"=>Some("<".into()),"gt"=>Some(">".into()),"quot"=>Some("\"".into()),"apos"|"#39"=>Some("'".into()),
        "nbsp"=>Some(" ".into()),"ndash"=>Some("–".into()),"mdash"=>Some("—".into()),"hellip"=>Some("…".into()),
        _=> {
            let number=if value.starts_with("#x") || value.starts_with("#X") { u32::from_str_radix(&value[2..],16).ok() } else if let Some(decimal)=value.strip_prefix('#') { decimal.parse().ok() } else { None };
            number.and_then(char::from_u32).filter(|c|*c!='\0').map(|c|c.to_string())
        }
    }
}
fn decode_entities(text:&str)->String {
    let mut result=String::new(); let mut remaining=text;
    while let Some(start)=remaining.find('&') {
        result.push_str(&remaining[..start]); remaining=&remaining[start..];
        if let Some(end)=remaining.find(';').filter(|end|*end<=16) {
            if let Some(decoded)=entity(&remaining[1..end]) { result.push_str(&decoded); remaining=&remaining[end+1..]; continue; }
        }
        result.push('&'); remaining=&remaining[1..];
    }
    result.push_str(remaining); result
}
fn plain_html(text:&str)->String {
    let mut output=String::new(); let mut remaining=text; let mut hidden:Option<String>=None;
    while let Some(open)=remaining.find('<') {
        if hidden.is_none() { output.push_str(&remaining[..open]); }
        remaining=&remaining[open..];
        let Some(close)=remaining.find('>') else { if hidden.is_none() { output.push_str(remaining); } remaining=""; break; };
        let tag=remaining[1..close].trim().to_ascii_lowercase();
        let name=tag.trim_start_matches('/').split(|c:char|c.is_whitespace()||c=='/').next().unwrap_or("");
        if hidden.as_deref().is_some_and(|name|tag.starts_with('/')&&name==tag[1..].trim()) { hidden=None; }
        else if hidden.is_none() {
            if ["script","style"].contains(&name) && !tag.starts_with('/') { hidden=Some(name.into()); }
            else if ["br","p","div","li","tr","h1","h2","h3"].contains(&name) { if !output.ends_with('\n') { output.push('\n'); } }
        }
        remaining=&remaining[close+1..];
    }
    if hidden.is_none() { output.push_str(remaining); }
    decode_entities(&output).trim().to_owned()
}
fn remove_media(text:&str)->String {
    let mut result=String::new(); let mut remaining=text;
    while let Some(start)=remaining.find("[sound:") {
        result.push_str(&remaining[..start]);
        let Some(end)=remaining[start..].find(']') else { result.push_str(&remaining[start..]); return result; };
        remaining=&remaining[start+end+1..];
    }
    result.push_str(remaining); result
}
fn column_name(value:&str)->String { value.trim().to_lowercase().replace(' ',"") }
fn is_front(value:&str)->bool { ["front","question","вопрос","лицеваясторона"].contains(&column_name(value).as_str()) }
fn is_back(value:&str)->bool { ["back","answer","ответ","обратнаясторона"].contains(&column_name(value).as_str()) }
fn parse(text:&str,separator_override:Option<&str>)->Result<Parsed> {
    ensure!(text.len() as u64<=MAX_FILE && !text.contains('\0'),"Нужен UTF-8 файл до 10 МБ без нулевых байтов");
    let text=text.trim_start_matches('\u{feff}'); let mut remaining=text;
    let mut separator=None; let mut html=false; let mut columns:Option<String>=None; let mut warnings=Vec::new();
    while remaining.starts_with('#') {
        let (line,tail)=remaining.split_once('\n').unwrap_or((remaining,""));
        let line=line.trim_end_matches('\r');
        let Some((name,value))=line[1..].split_once(':') else { break; };
        match name.to_ascii_lowercase().as_str() {
            "separator"=>separator=Some(delimiter(value)?),
            "html"=>html=value.trim().eq_ignore_ascii_case("true"),
            "columns"=>columns=Some(value.into()),
            "deck"|"deck column"|"notetype"|"notetype column"|"tags"|"tags column"|"guid column"=>{},
            _=>break,
        }
        remaining=tail;
    }
    let separator=if let Some(value)=separator_override.filter(|value|!value.is_empty()&&*value!="auto") { delimiter(value)? } else { separator.unwrap_or_else(||guess_delimiter(remaining)) };
    let mut data=rows(remaining,separator)?;
    let mut names=columns.map(|line|line.split(separator).map(str::to_owned).collect::<Vec<_>>());
    if names.is_none() && data.first().is_some_and(|row|row.len()>=2 && is_front(&row[0])&&is_back(&row[1])) { names=Some(data.remove(0)); }
    let front_index=names.as_ref().and_then(|names|names.iter().position(|name|is_front(name))).unwrap_or(0);
    let back_index=names.as_ref().and_then(|names|names.iter().position(|name|is_back(name))).unwrap_or(1);
    let context_index=if names.is_none() { Some(2) } else { names.as_ref().and_then(|names|names.iter().position(|name|["context","контекст"].contains(&column_name(name).as_str()))) };
    let tags_index=names.as_ref().and_then(|names|names.iter().position(|name|["tags","теги"].contains(&column_name(name).as_str())));
    let mut cards=Vec::new(); let mut seen=HashSet::new(); let mut skipped=0; let mut media=false; let mut cloze=false;
    ensure!(data.len()<=MAX_CARDS,"В одном файле должно быть не больше 10 000 карточек");
    for row in data {
        let Some(front)=row.get(front_index) else { skipped+=1; continue; };
        let Some(back)=row.get(back_index) else { skipped+=1; continue; };
        let mut context=context_index.and_then(|i|row.get(i)).cloned().unwrap_or_default();
        let mut back=back.clone();
        // Version <=0.4 exported its own context inside Back. Recognize only
        // that exact Posle-tagged wrapper; arbitrary decks keep their full Back.
        if html && context_index.is_none() && tags_index.and_then(|i|row.get(i)).is_some_and(|tags|tags.split_whitespace().any(|tag|tag=="posle")) {
            if let Some((content,_title))=back.rsplit_once("<br><small>") {
                if let Some((answer,old_context))=content.split_once("<br><br>") { context=old_context.into(); back=answer.into(); }
            }
        }
        let mut values=[front.clone(),back,context];
        for value in &mut values {
            let lower=value.to_ascii_lowercase();
            if lower.contains("[sound:")||lower.contains("<img")||lower.contains("<audio")||lower.contains("<video") { media=true; }
            if value.contains("{{c") { cloze=true; }
            if html { *value=plain_html(value); }
            *value=remove_media(value).trim().to_owned();
        }
        let [front,back,context]=values;
        if front.is_empty()||back.is_empty() { skipped+=1; continue; }
        let bytes=serde_json::to_vec(&json!([front,back,context]))?;
        let id=format!("import-{:x}",Sha256::digest(&bytes));
        if !seen.insert(id.clone()) { skipped+=1; continue; }
        // Preserve the app's exported card kind when it is explicitly in the
        // Anki Tags column; arbitrary external tags remain only import metadata.
        let kind=tags_index.and_then(|i|row.get(i)).and_then(|tags|tags.split_whitespace().find(|tag|["phrase","concept"].contains(tag))).unwrap_or("phrase");
        cards.push(json!({"id":id,"kind":kind,"front":front,"back":back,"context":context,"segmentIDs":[]}));
    }
    if skipped>0 { warnings.push(format!("Пропущено пустых, неполных или повторных строк: {skipped}.")); }
    if media { warnings.push("Изображения, видео и аудио из экспорта Anki не импортируются. Текст карточек сохранён.".into()); }
    if cloze { warnings.push("Обнаружены cloze-карточки. Они добавлены как обычный текст; автоматические пропуски не создаются.".into()); }
    ensure!(!cards.is_empty(),"В файле нет карточек с заполненными вопросом и ответом");
    ensure!(serde_json::to_vec(&cards)?.len()<=8*1_048_576-4096,"После преобразования колода превышает 8 МБ. Разделите файл на несколько колод.");
    Ok(Parsed{cards,warnings,skipped})
}
fn read(path:&Path)->Result<String> {
    ensure!(path.is_absolute(),"Выберите файл карточек");
    let info=fs::symlink_metadata(path).context("Файл карточек не найден")?;
    ensure!(info.is_file()&&!info.file_type().is_symlink()&&info.len()<=MAX_FILE,"Выберите обычный UTF-8 CSV/TSV файл до 10 МБ");
    let mut bytes=Vec::new(); let mut file=OpenOptions::new().read(true).custom_flags(libc::O_NOFOLLOW).open(path)?;
    ensure!(file.metadata()?.is_file()&&file.metadata()?.len()<=MAX_FILE,"Файл карточек слишком большой");
    (&mut file).take(MAX_FILE+1).read_to_end(&mut bytes)?;
    ensure!(bytes.len() as u64<=MAX_FILE,"Файл карточек слишком большой");
    String::from_utf8(bytes).context("Файл должен быть в UTF-8. Экспортируйте из Anki как текст с разделителями.")
}
pub fn preview(path:&Path,separator:Option<&str>)->Result<Value> {
    let source=read(path)?;
    let fingerprint=format!("{:x}",Sha256::digest(source.as_bytes()));
    let parsed=parse(&source,separator)?;
    Ok(json!({"total":parsed.cards.len(),"cards":parsed.cards,"warnings":parsed.warnings,"skipped":parsed.skipped,"sourceFingerprint":fingerprint}))
}
fn quoted(value:&str)->String {
    if value.contains(['\t','\n','\r','"']) { format!("\"{}\"",value.replace('"',"\"\"")) } else { value.into() }
}
pub fn import(root:&Path,path:&Path,separator:Option<&str>,title:Option<&str>)->Result<Value> {
    import_checked(root,path,separator,title,None)
}
pub fn import_checked(root:&Path,path:&Path,separator:Option<&str>,title:Option<&str>,expected_fingerprint:Option<&str>)->Result<Value> {
    import_scoped(root,path,separator,title,expected_fingerprint,None)
}
fn import_scoped(root:&Path,path:&Path,separator:Option<&str>,title:Option<&str>,expected_fingerprint:Option<&str>,folder_id:Option<&str>)->Result<Value> {
    if folder_id.is_some() { crate::folders::resolve(root,None,folder_id)?; }
    ensure!(root.is_absolute(),"Папка данных должна иметь абсолютный путь");
    let source=read(path)?;
    if let Some(expected)=expected_fingerprint {
        ensure!(expected.len()==64 && expected.bytes().all(|byte|byte.is_ascii_hexdigit()),"Некорректная проверка файла карточек. Обновите предпросмотр.");
        let current=format!("{:x}",Sha256::digest(source.as_bytes()));
        ensure!(current==expected,"Файл карточек изменился после предпросмотра. Откройте предпросмотр заново перед импортом.");
    }
    let parsed=parse(&source,separator)?;
    let title=title.filter(|title|!title.trim().is_empty()).map(str::trim).unwrap_or_else(||path.file_stem().and_then(|name|name.to_str()).unwrap_or("Импортированные карточки"));
    ensure!(title.len()<=512&&!title.contains('\0'),"Слишком длинное название колоды");
    let id=Uuid::new_v4().to_string(); let directory=crate::storage::meeting_directory(root,&id)?;
    DirBuilder::new().mode(0o700).create(&directory)?;
    let result=(||->Result<Value> {
        let mut output=OpenOptions::new().write(true).create_new(true).mode(0o600).custom_flags(libc::O_NOFOLLOW).open(directory.join("cards.tsv"))?;
        output.write_all(b"#separator:tab\n#html:false\n#columns:Front\tBack\tContext\tTags\n")?;
        for card in &parsed.cards {
            let row=[card["front"].as_str().unwrap(),card["back"].as_str().unwrap(),card["context"].as_str().unwrap(),card["kind"].as_str().unwrap()].map(quoted).join("\t");
            writeln!(output,"{row}")?;
        }
        output.sync_all()?;
        let date=Utc::now().timestamp_millis() as f64/1000.0;
        let summary=json!({"overview":"Импортированная колода карточек","items":[],"cards":parsed.cards,"provider":"import","model":"text-deck","generatedAt":date,"warnings":parsed.warnings,"overviewClaims":[]});
        crate::storage::atomic_json(&directory.join("summary.json"),&summary)?;
        let meeting=json!({"id":id,"title":title,"createdAt":date,"source":"cards.tsv","status":"ready","duration":0.0,"speakerNames":{},"completedTasks":[],"focus":"","recordingTracks":false,"hasVideo":false,"libraryKind":"cards"});
        // Metadata is published last: an unfinished import never appears in the
        // library and a failed write removes only this generated directory.
        publish_deck(root,&directory,&meeting,folder_id)?;
        Ok(json!({"meeting":meeting,"count":summary["cards"].as_array().unwrap().len(),"skipped":parsed.skipped,"warnings":summary["warnings"]}))
    })();
    if result.is_err() { let _=fs::remove_dir_all(&directory); }
    result
}
/// A deck becomes visible only after its canonical folder membership exists.
/// A crash before metadata publication can leave an inert context, never a
/// visible unscoped deck or a second imported copy on retry.
pub(super) fn publish_deck(root:&Path,directory:&Path,meeting:&Value,folder_id:Option<&str>)->Result<()> {
    let Some(folder)=folder_id else { return crate::storage::atomic_json(&directory.join("meta.json"),meeting); };
    let notes_dir=crate::notes::directory(root)?;let _lock=crate::notes::lock(&notes_dir)?;
    let mut data=crate::notes::load(&notes_dir)?;
    ensure!(data.folders.iter().any(|f|f.id==folder),"Папка удалена. Выберите папку заново.");
    let id=meeting["id"].as_str().context("Нет ID колоды")?;
    ensure!(!data.contexts.iter().any(|c|c.meeting_id==id),"Колода уже опубликована");
    data.contexts.push(serde_json::from_value(json!({"meetingID":id,"folderID":folder,"revision":1}))?);
    crate::notes::persist(&notes_dir,&data)?;
    if let Err(error)=crate::storage::atomic_json(&directory.join("meta.json"),meeting) {
        data.contexts.retain(|c|c.meeting_id!=id);
        let _=crate::notes::persist(&notes_dir,&data);
        return Err(error);
    }
    Ok(())
}
pub fn dispatch(root:&Path,value:&Value)->Result<Value> {
    if matches!(value["command"].as_str(), Some("card-trash-list" | "card-restore" | "card-trash-purge" | "cards-batch-apply" | "cards-batch-undo" | "cards-batch-recover")) { return operations::dispatch(root,value); }
    if !matches!(value["command"].as_str(), Some("cards-import" | "cards-import-preview")) { return workspace::dispatch(root, value); }
    let path=Path::new(value["path"].as_str().context("Выберите файл карточек")?);
    match value["command"].as_str() {
        Some("cards-import-preview")=>preview(path,value["separator"].as_str()),
        Some("cards-import")=>import_scoped(root,path,value["separator"].as_str(),value["title"].as_str(),value["expectedFingerprint"].as_str(),value["folderID"].as_str()),
        _=>bail!("Неизвестная команда карточек"),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::os::unix::fs::{symlink,PermissionsExt};
    #[test] fn utf8_bom_anki_headers_tags_and_html_preserve_text() {
        let data="\u{feff}#separator:tab\n#html:true\n#columns:Front\tBack\tTags\n<b>срок</b> &amp; date\tdeadline<br>срок\twork english\n";
        let result=parse(data,None).unwrap(); assert_eq!(result.cards.len(),1);
        assert_eq!(result.cards[0]["front"],"срок & date"); assert_eq!(result.cards[0]["back"],"deadline\nсрок"); assert_eq!(result.cards[0]["context"],"");
        assert!(result.cards[0]["segmentIDs"].as_array().unwrap().is_empty());
    }
    #[test] fn csv_quotes_commas_multiline_escaped_quotes_and_context() {
        let data="Front,Back,Context\r\n\"say, hello\",\"Он сказал \"\"привет\"\"\nпотом ушёл\",На встрече\r\n";
        let result=parse(data,None).unwrap(); assert_eq!(result.cards[0]["front"],"say, hello"); assert_eq!(result.cards[0]["back"],"Он сказал \"привет\"\nпотом ушёл"); assert_eq!(result.cards[0]["context"],"На встрече");
        let no_header=parse("Word\tСлово\tКонтекст",None).unwrap(); assert_eq!(no_header.cards[0]["context"],"Контекст");
    }
    #[test] fn duplicate_empty_rows_and_malformed_quotes_are_explicit() {
        let result=parse("one\tодин\none\tодин\nmissing\n\t\nsecond\tдва\n",None).unwrap(); assert_eq!(result.cards.len(),2); assert_eq!(result.skipped,2); assert_eq!(result.warnings.len(),1);
        assert!(parse("\"unclosed\tanswer",None).is_err()); assert!(parse("\"closed\"oops\tanswer",None).is_err()); assert!(parse("one\t",None).is_err());
    }
    #[test] fn html_never_executes_or_imports_media_and_cloze_is_warned() {
        let result=parse("#separator:tab\n#html:true\n<b>{{c1::Hello}}</b><script>alert(1)</script><img src='file:///private'>\t[sound:secret.mp3]Ответ &lt;b&gt; &nbsp; &#x1F44B;",None).unwrap();
        assert_eq!(result.cards[0]["front"],"{{c1::Hello}}"); assert_eq!(result.cards[0]["back"],"Ответ <b>   👋"); assert_eq!(result.warnings.len(),2);
        assert!(!result.cards[0].to_string().contains("secret.mp3"));
    }
    #[test] fn old_posle_export_restores_context_without_tags_or_title() {
        let result=parse("#separator:Tab\n#html:true\n#columns:Front\tBack\tTags\nPhrase\tПеревод<br><br>Контекст встречи<br><small>Встреча</small>\tposle phrase\n",None).unwrap();
        assert_eq!(result.cards[0]["back"],"Перевод"); assert_eq!(result.cards[0]["context"],"Контекст встречи"); assert_eq!(result.cards[0]["kind"],"phrase");
    }
    #[test] fn limits_and_wrong_encoding_reject_before_mutation() {
        assert!(parse(&"x".repeat(MAX_FILE as usize+1),None).is_err()); assert!(parse(&"a\tb\n".repeat(MAX_CARDS+1),None).is_err());
        let source=tempfile::tempdir().unwrap(); let path=source.path().join("bad.tsv"); fs::write(&path,[255,254,0]).unwrap();
        let root=tempfile::tempdir().unwrap(); assert!(import(root.path(),&path,None,None).is_err()); assert!(!root.path().join("meetings").exists());
        fs::write(&path,b"one\ttwo").unwrap(); let linked=source.path().join("link.tsv"); symlink(&path,&linked).unwrap(); assert!(preview(&linked,None).is_err());
    }
    #[test] fn preview_readonly_import_private_and_fsrs_review_works() {
        let source=tempfile::tempdir().unwrap(); let path=source.path().join("My cards.tsv"); let bytes=b"#separator:tab\n#html:false\n#columns:Front\tBack\tContext\tTags\nHello\tPrivet\tMeeting\tphrase\n"; fs::write(&path,bytes).unwrap();
        let root=tempfile::tempdir().unwrap(); let before=fs::read_dir(root.path()).unwrap().count(); assert_eq!(preview(&path,None).unwrap()["total"],1); assert_eq!(fs::read_dir(root.path()).unwrap().count(),before);
        let result=import(root.path(),&path,None,Some("English")).unwrap(); assert_eq!(result["count"],1); assert_eq!(result["meeting"]["title"],"English");
        let id=result["meeting"]["id"].as_str().unwrap(); let directory=root.path().join("meetings").join(id);
        for name in ["meta.json","summary.json","cards.tsv"] { assert_eq!(fs::metadata(directory.join(name)).unwrap().permissions().mode()&0o777,0o600); }
        assert_eq!(fs::metadata(&directory).unwrap().permissions().mode()&0o777,0o700); assert!(!directory.join("transcript.json").exists()); assert_eq!(fs::read(&path).unwrap(),bytes);
        let summary:Value=serde_json::from_slice(&fs::read(directory.join("summary.json")).unwrap()).unwrap(); let card_id=summary["cards"][0]["id"].as_str().unwrap();
        assert_eq!(crate::storage::review(root.path(),id,card_id,3).unwrap()["count"],1);
        crate::storage::atomic_json(&root.path().join("settings.json"),&json!({"features":{"cards":true}})).unwrap();
        let results=crate::search::search(root.path(),"Hello","cards",60).unwrap();
        assert_eq!(results["total"],1); assert_eq!(results["hits"][0]["cardID"],card_id);
        assert!(results["hits"][0]["segmentIDs"].as_array().unwrap().is_empty());
        let normalized=parse(&fs::read_to_string(directory.join("cards.tsv")).unwrap(),None).unwrap(); assert_eq!(normalized.cards,summary["cards"].as_array().unwrap().clone());
    }
    #[test] fn import_rejects_source_changed_after_preview_without_creating_a_deck() {
        let root=tempfile::tempdir().unwrap(); let source=tempfile::tempdir().unwrap(); let path=source.path().join("reviewed.tsv");
        fs::write(&path,"Reviewed question\tReviewed answer").unwrap();
        let preview=preview(&path,None).unwrap(); let fingerprint=preview["sourceFingerprint"].as_str().unwrap();
        assert_eq!(fingerprint.len(),64);
        fs::write(&path,"Different question\tUnreviewed answer").unwrap();
        let request=json!({"root":root.path(),"command":"cards-import","path":path,"expectedFingerprint":fingerprint});
        let error=crate::request(&request).unwrap_err().to_string(); assert!(error.contains("изменился"));
        assert!(!root.path().join("meetings").exists());
        fs::write(&path,"Reviewed question\tReviewed answer").unwrap();
        assert_eq!(crate::request(&request).unwrap()["count"],1);
    }
    #[test] fn new_decks_and_imports_publish_with_the_selected_folder_or_leave_no_visible_data() {
        let root=tempfile::tempdir().unwrap();let source=tempfile::tempdir().unwrap();let path=source.path().join("cards.tsv");fs::write(&path,"Word\tСлово").unwrap();
        let folder=crate::folders::save(root.path(),crate::folders::Folder{id:"english".into(),name:"Английский".into(),revision:0,overrides:json!({"features":{"cards":true}})}).unwrap();
        let imported=dispatch(root.path(),&json!({"command":"cards-import","path":path,"folderID":folder.id})).unwrap();let id=imported["meeting"]["id"].as_str().unwrap();assert_eq!(crate::folders::resolve(root.path(),Some(id),None).unwrap().folder_id.as_deref(),Some("english"));
        let created=dispatch(root.path(),&json!({"command":"card-save","front":"Вопрос","back":"Answer","folderID":"english"})).unwrap();let created_id=created["meeting"]["id"].as_str().unwrap();assert_eq!(crate::folders::resolve(root.path(),Some(created_id),None).unwrap().folder_id.as_deref(),Some("english"));
        let before=crate::storage::list_meetings(root.path()).unwrap();assert!(dispatch(root.path(),&json!({"command":"cards-import","path":path,"folderID":"missing"})).is_err());assert!(dispatch(root.path(),&json!({"command":"card-save","front":"Вопрос","back":"Answer","folderID":"missing"})).is_err());assert_eq!(crate::storage::list_meetings(root.path()).unwrap(),before);
    }
    #[test] fn standalone_decks_cannot_escape_symlinked_library() {
        let root=tempfile::tempdir().unwrap(); let outside=tempfile::tempdir().unwrap(); let source=tempfile::tempdir().unwrap(); let path=source.path().join("cards.csv"); fs::write(&path,"Word,Answer").unwrap();
        symlink(outside.path(),root.path().join("meetings")).unwrap(); assert!(import(root.path(),&path,None,None).is_err()); assert_eq!(fs::read_dir(outside.path()).unwrap().count(),0);
    }
}
