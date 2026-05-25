require "marten"

module MartenEncodedId
  module Routing
    # Custom Marten route parameter type that matches the URL shape of an
    # encoded id (Hashids/Sqids output, optionally with annotation prefix,
    # optional slug prefix, and optional group separators).
    #
    # This parameter type does NOT decode the value automatically — the
    # encoded id format is per-model (each model has its own salt + coder),
    # so a generic parameter type can't know which model to decode against.
    # Instead `loads` returns the raw encoded string and handlers call
    # `Model.find_by_encoded_id(params["..."]?.try(&.as(String)))` to look
    # up the record.
    #
    # Usage:
    #
    #     # In config/routes.cr:
    #     Marten.routes.draw do
    #       path "/widgets/<widget_id:encoded_id>", WidgetHandler, name: "widget_detail"
    #     end
    #
    #     # In a handler:
    #     encoded = params["widget_id"].as(::String)
    #     widget  = Widget.find_by_encoded_id!(encoded)
    #
    # The regex accepts:
    #   - ASCII letters and digits (the Hashids/Sqids alphabet output);
    #   - `-` (Hashids group separator default and our slugged_id `--`);
    #   - `_` (default annotated_id separator).
    #
    # If a host customises `Configuration#group_separator` /
    # `annotated_id_separator` / `slugged_id_separator` to use other
    # characters, this default regex still works for the common case but a
    # bespoke parameter type may be needed. The accepted set was chosen to
    # be a strict superset of the default separators while still narrow
    # enough to avoid swallowing path-traversal characters.
    class Parameter < ::Marten::Routing::Parameter::Base
      def dumps(value) : Nil | ::String
        value.as?(::String)
      end

      # M7 — gate the captured URL segment through `valid?` before we
      # let it through to a handler. The regex (below) already
      # restricts the alphabet to `[A-Za-z0-9_\-]+`, but it can't catch
      # *structural* malformations — a leading/trailing separator, an
      # empty slug-half, etc. We catch those here.
      #
      # Returning `nil` causes the path matcher to populate the named
      # capture with `nil` rather than the raw string, which a handler
      # sees as `params["widget_id"]? # => nil` (or a typed
      # `String?` cast). That's the conservative "no, this URL doesn't
      # really match" signal — calling `find_by_encoded_id` on a `nil`
      # would have to be guarded by the handler anyway.
      def loads(value : ::String) : ::String?
        return nil if value.empty?
        # Prefer the slugged check first — `--` is more specific than
        # `_` and any input containing `--` was very likely meant as a
        # slugged id.
        if value.includes?("--")
          return nil unless ::MartenEncodedId::SluggedId.valid?(value)
        else
          return nil unless ::MartenEncodedId::AnnotatedId.valid?(value)
        end
        value
      end

      def regex : Regex
        REGEX
      end

      # Letters/digits + `-` (group sep, slug sep) + `_` (annotation sep).
      # Length >= 1.
      private REGEX = /[A-Za-z0-9_\-]+/
    end
  end
end

::Marten::Routing::Parameter.register(:encoded_id, ::MartenEncodedId::Routing::Parameter)
