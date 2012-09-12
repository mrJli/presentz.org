http = require "http"
xml2json = require "xml2json"
node_slideshare = require "slideshare"
utils = require "./utils"
_ = require "underscore"

storage = null
slideshare = null

init = (s, slideshare_conf) ->
  storage = s
  slideshare = new node_slideshare slideshare_conf.api_key, slideshare_conf.shared_secret

safe_next = (next, err) ->
  err = new Error(err) if !(err instanceof Error)
  next(err)

presentations = (req, res, next) ->
  storage.from_user_to_presentations req.user, (err, presentations) ->
    return safe_next(next, err) if err?

    res.send presentations

has_slides = (presentation) ->
  return false if !presentation.chapters?

  for chapter in presentation.chapters
    return true if chapter.slides?

  false

presentation_save_published = (presentation, callback) ->
  allowed_fields = [ "@class", "@type", "title", "speaker", "_type", "published", "id", "in", "out", "@version", "@rid" ]

  utils.ensure_only_wanted_fields_in presentation, allowed_fields

  storage.save presentation, callback

presentation_save_everything = (user, presentation, callback) ->
  allowed_map_of_fields =
    presentation: [ "@class", "@type", "@version", "@rid", "in", "out", "id", "title", "time", "speaker", "_type", "published", "chapters" ]
    chapter: [ "@class", "@type", "@version", "@rid", "in", "out", "duration", "_type", "_index", "video", "slides" ]
    video: [ "url", "thumb" ]
    slide: [ "@class", "@type", "@version", "@rid", "in", "out", "url", "title", "time", "_type", "public_url" ]

  utils.visit_presentation presentation, utils.ensure_only_wanted_map_of_fields_in, allowed_map_of_fields

  save_all = (objs, callback) ->
    return callback(undefined, []) if objs.length is 0

    saved_objs = []
    for obj in objs
      save obj, (err, obj) ->
        return callback(err) if err?
        saved_objs.push(obj)
        return callback(undefined, saved_objs) if saved_objs.length is objs.length

  save = (obj, callback) ->
    is_new = !obj["@rid"]?
    cb = (err, obj) ->
      return callback(err) if err?
      obj.is_new = is_new
      callback(undefined, obj, is_new)

    if is_new
      storage.create obj, cb
    else
      storage.save obj, cb

  link_all_new = (objs, node_to_link_to, storage_function, callback) ->
    new_objs = _.filter objs, (obj) -> obj.is_new? and obj.is_new

    return callback(undefined) if new_objs.length is 0

    linked_objs = []
    for obj in new_objs
      storage_function obj, node_to_link_to, (err, link) ->
        return callback(err) if err?
        linked_objs.push(link)
        return callback(undefined) if linked_objs.length is new_objs.length

  save_all_chapters = (chapters, callback) ->
    return callback(undefined, []) if chapters.length is 0
    saved_chapters = []
    for chapter in chapters
      save_all chapter.slides, (err, slides) ->
        return callback(err) if err?
        delete chapter.slides
        save chapter, (err, chapter) ->
          return callback(err) if err?
          link_all_new slides, chapter, storage.link_slide_to_chapter, (err) ->
            return callback(err) if err?
            saved_chapters.push(chapter)
            return callback(undefined, saved_chapters) if saved_chapters.length is chapters.length

  save_all_chapters presentation.chapters, (err, chapters) ->
    return callback(err) if err?
    delete presentation.chapters
    save presentation, (err, presentation, was_new) ->
      return callback(err) if err?
      link_all_new chapters, presentation, storage.link_chapter_to_presentation, (err) ->
        return callback(err) if err?

        storage.link_user_to_presentation user, presentation, (err) ->
          return callback(err) if err?

          storage.load_entire_presentation_from_id presentation.id, callback

presentation_save = (req, res, next) ->
  presentation = req.body

  callback = (err, new_presentation) ->
    return safe_next(next, err) if err?

    res.send new_presentation

  if has_slides(presentation)
    presentation_save_everything(req.user, presentation, callback)
  else
    presentation_save_published(presentation, callback)

presentation_load = (req, res, next) ->
  storage.load_entire_presentation_from_id req.params.presentation, (err, presentation) ->
    return safe_next(next, err) if err?

    res.send presentation

slideshare_slides_of = (req, res, next) ->
  request_params =
    host: "cdn.slidesharecdn.com"
    port: 80
    path: "/#{req.params.doc_id}.xml"

  request = http.request request_params, (response) ->
    response.setEncoding "utf8"
    xml = ""
    response.on "data", (chunk) ->
      xml = xml.concat(chunk)
    response.on "end", () ->
      res.contentType "application/json"
      res.send xml2json.toJson(xml)

  request.on "error", (e) ->
    console.warn arguments
    res.render {}

  request.end()

slideshare_url_to_doc_id = (req, res, next) ->
  slideshare.getSlideshowByURL req.query.url, { detailed: 1 }, (xml) ->
    res.contentType "application/json"
    res.send xml2json.toJson(xml)

delete_slide = (req, res, next) ->
  storage.delete_slide req.params.node_id, (err) ->
    return next(err) if err?

    res.send 200

exports.init = init
exports.presentations = presentations
exports.presentation_save = presentation_save
exports.presentation_load = presentation_load
exports.slideshare_slides_of = slideshare_slides_of
exports.slideshare_url_to_doc_id = slideshare_url_to_doc_id
exports.delete_slide = delete_slide