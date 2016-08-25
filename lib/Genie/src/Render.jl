module Render

export respond, json, mustache, ejl, redirect_to

using Genie
using Util
using JSON
using Ejl
using Mustache

const CONTENT_TYPES = Dict{Symbol, AbstractString}(
  :json   => "text/json",
  :html   => "text/html",
  :js     => "application/javascript",
  :text   => "text/plain"
)
const MUSTACHE_YIELD_VAR_NAME = :yield
const EJL_YIELD_VAR_NAME = :yield

function json(resource::Symbol, action::Symbol; vars...)
  spawn_splatted_vars(vars)
  r = include(abspath(joinpath("app", "resources", string(resource), "views", string(action) * ".$RENDER_JSON_EXT")))

  Dict(:json => r)
end

function ejl(resource::Symbol, action::Symbol; layout::Union{Symbol, AbstractString} = :app, render_layout::Bool = true, vars...)
  spawn_splatted_vars(vars)

  template = Ejl.template_from_file(abspath(joinpath(Genie.APP_PATH, "app", "resources", string(resource), "views", string(action) * ".$RENDER_EJL_EXT")))
  r = Ejl.render_tpl(template)

  if render_layout
    layout = Ejl.template_from_file(abspath(joinpath(Genie.APP_PATH, "app", "layouts", string(layout) * ".$RENDER_EJL_EXT")))
    spawn_vars(EJL_YIELD_VAR_NAME, r)
    r = Ejl.render_tpl(layout)
  end

  Dict(:html => r)
end
function ejl(content::AbstractString, layout::Union{Symbol, AbstractString} = :app, vars...)
  spawn_splatted_vars(vars)
  layout = Ejl.template_from_file(abspath(joinpath(Genie.APP_PATH, "app", "layouts", string(layout) * ".$RENDER_EJL_EXT")))
  spawn_vars(EJL_YIELD_VAR_NAME, content)
  r = Ejl.render_tpl(layout)

  Dict(:html => r)
end
function ejl(content::Vector{AbstractString}; vars...)
  spawn_splatted_vars(vars)
  Ejl.render_tpl(content)
end

function mustache(resource::Symbol, action::Symbol; layout::Union{Symbol, AbstractString} = :app, render_layout::Bool = true, vars...)
  spawn_splatted_vars(vars)

  template = Mustache.template_from_file(abspath(joinpath("app", "resources", string(resource), "views", string(action) * ".$RENDER_MUSTACHE_EXT")))
  vals = merge(special_vals(), Dict([k => v for (k, v) in vars]))
  r = Mustache.render(template, vals)

  if render_layout
    layout = Mustache.template_from_file(abspath(joinpath("app", "layouts", string(layout) * ".$RENDER_MUSTACHE_EXT")))
    vals[MUSTACHE_YIELD_VAR_NAME] = r
    r = Mustache.render(layout, vals)
  end

  Dict(:html => r)
end
function mustache(content::AbstractString, layout::Union{Symbol, AbstractString} = :app, vars...)
  spawn_splatted_vars(vars)
  vals = merge(special_vals(), Dict([k => v for (k, v) in vars]))
  layout = Mustache.template_from_file(abspath(joinpath("app", "layouts", string(layout) * ".$RENDER_MUSTACHE_EXT")))
  vals[MUSTACHE_YIELD_VAR_NAME] = content
  r = Mustache.render(layout, vals)

  Dict(:html => r)
end

function redirect_to(location::AbstractString, code::Int = 302, headers::Dict{AbstractString, AbstractString} = Dict{AbstractString, AbstractString}())
  headers["Location"] = location
  respond(Dict(:text => ""), code, headers)
end

function spawn_splatted_vars(vars, m::Module = current_module())
  for arg in vars
    k, v = arg
    spawn_vars(k, v, m)
  end
end

function special_vals()
  Dict{Symbol,Any}(
    :genie_assets_path => Genie.config.assets_path
  )
end

function spawn_vars(key, value, m::Module = current_module())
  eval(m, :(const $key = $value))
end

function structure_to_dict(structure, resource = nothing)
  data_item = Dict()
  for (k, v) in structure
    k = endswith(string(k), "_") ? Symbol(string(k)[1:end-1]) : k
    data_item[Symbol(k)] =  if isa(v, Symbol)
                              getfield(current_module().eval(resource), v) |> Util.expand_nullable
                            elseif isa(v, Function)
                              v()
                            else
                              v
                            end
  end

  data_item
end

function respond(body, code::Int = 200, headers::Dict{AbstractString,AbstractString} = Dict{AbstractString, AbstractString}())
  body =  if haskey(body, :json)
            headers["Content-Type"] = CONTENT_TYPES[:json]
            JSON.json(body[:json])
          elseif haskey(body, :html)
            headers["Content-Type"] = CONTENT_TYPES[:html]
            body[:html]
          elseif haskey(body, :js)
            headers["Content-Type"] = CONTENT_TYPES[:js]
            body[:js]
          elseif haskey(body, :text)
            headers["Content-Type"] = CONTENT_TYPES[:text]
            body[:text]
          else
            headers["Content-Type"] = CONTENT_TYPES[:json]
            body
          end

  (code, headers, body)
end
function respond(response::Tuple, headers::Dict{AbstractString,AbstractString} = Dict{AbstractString, AbstractString}())
  respond(response[1], response[2], headers)
end
function respond(response::Response)
  return response
end

function http_error(status_code; id = "resource_not_found", code = "404-0001", title = "Not found", detail = "The requested resource was not found")
  respond(detail, status_code, Dict{AbstractString, AbstractString}())
end

# =================================================== #

module JSONAPI

using Render
using Genie

export builder, elem, pagination

function builder(; params...)
  response = Dict()
  for p in params
    response[p[1]] =  if isa(p[2], Function)
                        p[2]()
                      else
                        p[2]
                      end
  end

  response
end

function elem(collection, instance_name; structure...)
  if ! isa(collection, Array)
    Render.spawn_vars(instance_name, collection)
    return Render.structure_to_dict(structure, collection)
  end

  data_items = []
  for resource in collection
    Render.spawn_vars(instance_name, resource)
    push!(data_items, Render.structure_to_dict(structure, resource))
  end

  data_items
end

function elem(instance_var; structure...)
  () -> Render.structure_to_dict(structure,  if isa(instance_var, Symbol)
                                                current_module().eval(instance_var)
                                              else
                                                instance_var
                                              end)
end

function elem(;structure...)
  () -> Render.structure_to_dict(structure)
end

function http_error(status_code; id = "resource_not_found", code = "404-0001", title = "Not found", detail = "The requested resource was not found")
  Dict{Symbol, Any}(
    :errors => elem(
                      id        = id,
                      status    = status_code,
                      code      = code,
                      title     = title,
                      detail    = detail
                    )()
  ), status_code
end

function pagination(path::AbstractString, total_items::Int; current_page::Int = 1, page_size::Int = Genie.genie_app.config.pagination_jsonapi_default_items_per_page)
  pg = Dict{Symbol, AbstractString}()
  pg[:first] = path

  pg[:first] = path * "?" * Genie.genie_app.config.pagination_jsonapi_page_param_name * "[number]=1&" *
                Genie.genie_app.config.pagination_jsonapi_page_param_name * "[size]=" * string(page_size)

  if current_page > 1
    pg[:prev] = path * "?" * Genie.genie_app.config.pagination_jsonapi_page_param_name * "[number]=" * string(current_page - 1) * "&" *
                  Genie.genie_app.config.pagination_jsonapi_page_param_name * "[size]=" * string(page_size)
  end

  if current_page * page_size < total_items
    pg[:next] = path * "?" * Genie.genie_app.config.pagination_jsonapi_page_param_name * "[number]=" * string(current_page + 1) * "&" *
                  Genie.genie_app.config.pagination_jsonapi_page_param_name * "[size]=" * string(page_size)
  end

  pg[:last] = path * "?" * Genie.genie_app.config.pagination_jsonapi_page_param_name * "[number]=" * string(Int(ceil(total_items / page_size))) * "&" *
                Genie.genie_app.config.pagination_jsonapi_page_param_name * "[size]=" * string(page_size)

  pg
end

end # end module Render.JSONAPI
end # end module Render