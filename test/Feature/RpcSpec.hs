module Feature.RpcSpec where

import qualified Data.ByteString.Lazy as BL (empty)

import Network.Wai      (Application)
import Network.Wai.Test (SResponse (simpleBody, simpleStatus))

import Network.HTTP.Types
import Test.Hspec          hiding (pendingWith)
import Test.Hspec.Wai
import Test.Hspec.Wai.JSON
import Text.Heredoc

import PostgREST.Types (PgVersion, pgVersion100, pgVersion109,
                        pgVersion110, pgVersion112, pgVersion114,
                        pgVersion95)
import Protolude       hiding (get)
import SpecHelper

spec :: PgVersion -> SpecWith Application
spec actualPgVersion =
  describe "remote procedure call" $ do
    context "a proc that returns a set" $ do
      it "returns paginated results" $ do
        request methodPost "/rpc/getitemrange"
                (rangeHdrs (ByteRangeFromTo 0 0))  [json| { "min": 2, "max": 4 } |]
           `shouldRespondWith` [json| [{"id":3}] |]
            { matchStatus = 200
            , matchHeaders = ["Content-Range" <:> "0-0/*"]
            }
        request methodGet "/rpc/getitemrange?min=2&max=4"
                (rangeHdrs (ByteRangeFromTo 0 0)) ""
           `shouldRespondWith` [json| [{"id":3}] |]
            { matchStatus = 200
            , matchHeaders = ["Content-Range" <:> "0-0/*"]
            }
        request methodHead "/rpc/getitemrange?min=2&max=4"
                (rangeHdrs (ByteRangeFromTo 0 0)) ""
           `shouldRespondWith` ""
            { matchStatus = 200
            , matchHeaders = ["Content-Range" <:> "0-0/*"]
            }

      it "includes total count if requested" $ do
        request methodPost "/rpc/getitemrange"
                (rangeHdrsWithCount (ByteRangeFromTo 0 0))
                [json| { "min": 2, "max": 4 } |]
           `shouldRespondWith` [json| [{"id":3}] |]
            { matchStatus = 206 -- it now knows the response is partial
            , matchHeaders = ["Content-Range" <:> "0-0/2"]
            }
        request methodGet "/rpc/getitemrange?min=2&max=4"
                (rangeHdrsWithCount (ByteRangeFromTo 0 0)) ""
           `shouldRespondWith` [json| [{"id":3}] |]
            { matchStatus = 206
            , matchHeaders = ["Content-Range" <:> "0-0/2"]
            }
        request methodHead "/rpc/getitemrange?min=2&max=4"
                (rangeHdrsWithCount (ByteRangeFromTo 0 0)) ""
           `shouldRespondWith` ""
            { matchStatus = 206
            , matchHeaders = ["Content-Range" <:> "0-0/2"]
            }

      it "returns proper json" $ do
        post "/rpc/getitemrange" [json| { "min": 2, "max": 4 } |] `shouldRespondWith`
          [json| [ {"id": 3}, {"id":4} ] |]
          { matchHeaders = [matchContentTypeJson] }
        get "/rpc/getitemrange?min=2&max=4" `shouldRespondWith`
          [json| [ {"id": 3}, {"id":4} ] |]
          { matchHeaders = [matchContentTypeJson] }

      it "returns CSV" $ do
        request methodPost "/rpc/getitemrange"
                (acceptHdrs "text/csv")
                [json| { "min": 2, "max": 4 } |]
           `shouldRespondWith` "id\n3\n4"
            { matchStatus = 200
            , matchHeaders = ["Content-Type" <:> "text/csv; charset=utf-8"]
            }
        request methodGet "/rpc/getitemrange?min=2&max=4"
                (acceptHdrs "text/csv") ""
           `shouldRespondWith` "id\n3\n4"
            { matchStatus = 200
            , matchHeaders = ["Content-Type" <:> "text/csv; charset=utf-8"]
            }
        request methodHead "/rpc/getitemrange?min=2&max=4"
                (acceptHdrs "text/csv") ""
           `shouldRespondWith` ""
            { matchStatus = 200
            , matchHeaders = ["Content-Type" <:> "text/csv; charset=utf-8"]
            }

    context "unknown function" $ do
      it "returns 404" $
        post "/rpc/fakefunc" [json| {} |] `shouldRespondWith` 404
      it "should fail with 404 on unknown proc name" $
        get "/rpc/fake" `shouldRespondWith` 404
      it "should fail with 404 on unknown proc args" $ do
        get "/rpc/sayhello" `shouldRespondWith` 404
        get "/rpc/sayhello?any_arg=value" `shouldRespondWith` 404
      it "should not ignore unknown args and fail with 404" $
        get "/rpc/add_them?a=1&b=2&smthelse=blabla" `shouldRespondWith`
        let
          message :: Text
          message
            | actualPgVersion < pgVersion95 = "function test.add_them(a := integer, b := integer, smthelse := text) does not exist"
            | otherwise = "function test.add_them(a => integer, b => integer, smthelse => text) does not exist"
        in [json| {
          "code": "42883",
          "details": null,
          "hint": "No function matches the given name and argument types. You might need to add explicit type casts.",
          "message": #{message} } |]
        { matchStatus  = 404
        , matchHeaders = [matchContentTypeJson]
        }

    it "works when having uppercase identifiers" $ do
      get "/rpc/quotedFunction?user=mscott&fullName=Michael Scott&SSN=401-32-XXXX" `shouldRespondWith`
        [json|{"user": "mscott", "fullName": "Michael Scott", "SSN": "401-32-XXXX"}|]
        { matchHeaders = [matchContentTypeJson] }
      post "/rpc/quotedFunction"
        [json|{"user": "dschrute", "fullName": "Dwight Schrute", "SSN": "030-18-XXXX"}|]
        `shouldRespondWith`
        [json|{"user": "dschrute", "fullName": "Dwight Schrute", "SSN": "030-18-XXXX"}|]
        { matchHeaders = [matchContentTypeJson] }

    context "shaping the response returned by a proc" $ do
      it "returns a project" $ do
        post "/rpc/getproject" [json| { "id": 1} |] `shouldRespondWith`
          [str|[{"id":1,"name":"Windows 7","client_id":1}]|]
        get "/rpc/getproject?id=1" `shouldRespondWith`
          [str|[{"id":1,"name":"Windows 7","client_id":1}]|]

      it "can filter proc results" $ do
        post "/rpc/getallprojects?id=gt.1&id=lt.5&select=id" [json| {} |] `shouldRespondWith`
          [json|[{"id":2},{"id":3},{"id":4}]|]
          { matchHeaders = [matchContentTypeJson] }
        get "/rpc/getallprojects?id=gt.1&id=lt.5&select=id" `shouldRespondWith`
          [json|[{"id":2},{"id":3},{"id":4}]|]
          { matchHeaders = [matchContentTypeJson] }

      it "can limit proc results" $ do
        post "/rpc/getallprojects?id=gt.1&id=lt.5&select=id?limit=2&offset=1" [json| {} |]
          `shouldRespondWith` [json|[{"id":3},{"id":4}]|]
             { matchStatus = 200
             , matchHeaders = ["Content-Range" <:> "1-2/*"] }
        get "/rpc/getallprojects?id=gt.1&id=lt.5&select=id?limit=2&offset=1"
          `shouldRespondWith` [json|[{"id":3},{"id":4}]|]
             { matchStatus = 200
             , matchHeaders = ["Content-Range" <:> "1-2/*"] }

      it "select works on the first level" $ do
        post "/rpc/getproject?select=id,name" [json| { "id": 1} |] `shouldRespondWith`
          [str|[{"id":1,"name":"Windows 7"}]|]
        get "/rpc/getproject?id=1&select=id,name" `shouldRespondWith`
          [str|[{"id":1,"name":"Windows 7"}]|]

    context "foreign entities embedding" $ do
      it "can embed if related tables are in the exposed schema" $ do
        post "/rpc/getproject?select=id,name,client(id),tasks(id)" [json| { "id": 1} |] `shouldRespondWith`
          [json|[{"id":1,"name":"Windows 7","client":{"id":1},"tasks":[{"id":1},{"id":2}]}]|]
          { matchHeaders = [matchContentTypeJson] }
        get "/rpc/getproject?id=1&select=id,name,client(id),tasks(id)" `shouldRespondWith`
          [json|[{"id":1,"name":"Windows 7","client":{"id":1},"tasks":[{"id":1},{"id":2}]}]|]
          { matchHeaders = [matchContentTypeJson] }

      it "cannot embed if the related table is not in the exposed schema" $ do
        post "/rpc/single_article?select=*,article_stars(*)" [json|{ "id": 1}|]
          `shouldRespondWith` 400
        get "/rpc/single_article?id=1&select=*,article_stars(*)"
          `shouldRespondWith` 400

      it "can embed if the related tables are in a hidden schema but exposed as views" $ do
        post "/rpc/single_article?select=id,articleStars(userId)" [json|{ "id": 2}|]
          `shouldRespondWith` [json|[{"id": 2, "articleStars": [{"userId": 3}]}]|]
          { matchHeaders = [matchContentTypeJson] }
        get "/rpc/single_article?id=2&select=id,articleStars(userId)"
          `shouldRespondWith` [json|[{"id": 2, "articleStars": [{"userId": 3}]}]|]
          { matchHeaders = [matchContentTypeJson] }

    context "a proc that returns an empty rowset" $
      it "returns empty json array" $ do
        post "/rpc/test_empty_rowset" [json| {} |] `shouldRespondWith`
          [json| [] |]
          { matchHeaders = [matchContentTypeJson] }
        get "/rpc/test_empty_rowset" `shouldRespondWith`
          [json| [] |]
          { matchHeaders = [matchContentTypeJson] }

    context "proc return types" $ do
      context "returns text" $ do
        it "returns proper json" $
          post "/rpc/sayhello" [json| { "name": "world" } |] `shouldRespondWith`
            [json|"Hello, world"|]
            { matchHeaders = [matchContentTypeJson] }

        it "can handle unicode" $
          post "/rpc/sayhello" [json| { "name": "￥" } |] `shouldRespondWith`
            [json|"Hello, ￥"|]
            { matchHeaders = [matchContentTypeJson] }

      it "returns array" $
        post "/rpc/ret_array" [json|{}|] `shouldRespondWith`
          [json|[1, 2, 3]|]
          { matchHeaders = [matchContentTypeJson] }

      it "returns setof integers" $
        post "/rpc/ret_setof_integers" [json|{}|] `shouldRespondWith`
          [json|[{ "ret_setof_integers": 1 },
                 { "ret_setof_integers": 2 },
                 { "ret_setof_integers": 3 }]|]
          { matchHeaders = [matchContentTypeJson] }

      it "returns enum value" $
        post "/rpc/ret_enum" [json|{ "val": "foo" }|] `shouldRespondWith`
          [json|"foo"|]
          { matchHeaders = [matchContentTypeJson] }

      it "returns domain value" $
        post "/rpc/ret_domain" [json|{ "val": "8" }|] `shouldRespondWith`
          [json|8|]
          { matchHeaders = [matchContentTypeJson] }

      it "returns range" $
        post "/rpc/ret_range" [json|{ "low": 10, "up": 20 }|] `shouldRespondWith`
          [json|"[10,20)"|]
          { matchHeaders = [matchContentTypeJson] }

      it "returns row of scalars" $
        post "/rpc/ret_scalars" [json|{}|] `shouldRespondWith`
          [json|[{"a":"scalars", "b":"foo", "c":1, "d":"[10,20)"}]|]
          { matchHeaders = [matchContentTypeJson] }

      it "returns composite type in exposed schema" $
        post "/rpc/ret_point_2d" [json|{}|] `shouldRespondWith`
          [json|[{"x": 10, "y": 5}]|]
          { matchHeaders = [matchContentTypeJson] }

      it "cannot return composite type in hidden schema" $
        post "/rpc/ret_point_3d" [json|{}|] `shouldRespondWith` 401

      it "returns single row from table" $
        post "/rpc/single_article?select=id" [json|{"id": 2}|] `shouldRespondWith`
          [json|[{"id": 2}]|]
          { matchHeaders = [matchContentTypeJson] }

      it "returns null for void" $
        post "/rpc/ret_void" [json|{}|] `shouldRespondWith`
          [json|null|]
          { matchHeaders = [matchContentTypeJson] }

    context "proc argument types" $ do
      it "accepts a variety of arguments" $
        post "/rpc/varied_arguments"
            [json| {
              "double": 3.1,
              "varchar": "hello",
              "boolean": true,
              "date": "20190101",
              "money": 0,
              "enum": "foo",
              "integer": 43,
              "json": {"some key": "some value"},
              "jsonb": {"another key": [1, 2, "3"]}
            } |]
          `shouldRespondWith`
            [json|"Hi"|]
            { matchHeaders = [matchContentTypeJson] }

      it "parses embedded JSON arguments as JSON" $
        post "/rpc/json_argument"
            [json| { "arg": { "key": 3 } } |]
          `shouldRespondWith`
            [json|"object"|]
            { matchHeaders = [matchContentTypeJson] }

      when (actualPgVersion < pgVersion100) $
        it "parses quoted JSON arguments as JSON (Postgres < 10)" $
          post "/rpc/json_argument"
              [json| { "arg": "{ \"key\": 3 }" } |]
            `shouldRespondWith`
              [json|"object"|]
              { matchHeaders = [matchContentTypeJson] }

      when ((actualPgVersion >= pgVersion109 && actualPgVersion < pgVersion110)
            || actualPgVersion >= pgVersion114) $
        it "parses quoted JSON arguments as JSON string (from Postgres 10.9, 11.4)" $
          post "/rpc/json_argument"
              [json| { "arg": "{ \"key\": 3 }" } |]
            `shouldRespondWith`
              [json|"string"|]
              { matchHeaders = [matchContentTypeJson] }

    context "improper input" $ do
      it "rejects unknown content type even if payload is good" $ do
        request methodPost "/rpc/sayhello"
          (acceptHdrs "audio/mpeg3") [json| { "name": "world" } |]
            `shouldRespondWith` 415
        request methodGet "/rpc/sayhello?name=world"
          (acceptHdrs "audio/mpeg3") ""
            `shouldRespondWith` 415
      it "rejects malformed json payload" $ do
        p <- request methodPost "/rpc/sayhello"
          (acceptHdrs "application/json") "sdfsdf"
        liftIO $ do
          simpleStatus p `shouldBe` badRequest400
          isErrorFormat (simpleBody p) `shouldBe` True
      it "treats simple plpgsql raise as invalid input" $ do
        p <- post "/rpc/problem" "{}"
        liftIO $ do
          simpleStatus p `shouldBe` badRequest400
          isErrorFormat (simpleBody p) `shouldBe` True

    context "unsupported verbs" $ do
      it "DELETE fails" $
        request methodDelete "/rpc/sayhello" [] ""
          `shouldRespondWith`
          [json|{"message":"Bad Request"}|]
          { matchStatus  = 405
          , matchHeaders = [matchContentTypeJson]
          }
      it "PATCH fails" $
        request methodPatch "/rpc/sayhello" [] ""
          `shouldRespondWith` 405
      it "OPTIONS fails" $
        -- TODO: should return info about the function
        request methodOptions "/rpc/sayhello" [] ""
          `shouldRespondWith` 405

    it "executes the proc exactly once per request" $ do
      post "/rpc/callcounter" [json| {} |] `shouldRespondWith`
        [json|1|]
        { matchHeaders = [matchContentTypeJson] }
      post "/rpc/callcounter" [json| {} |] `shouldRespondWith`
        [json|2|]
        { matchHeaders = [matchContentTypeJson] }

    context "a proc that receives no parameters" $ do
      it "interprets empty string as empty json object on a post request" $
        post "/rpc/noparamsproc" BL.empty `shouldRespondWith`
          [json| "Return value of no parameters procedure." |]
          { matchHeaders = [matchContentTypeJson] }
      it "interprets empty string as a function with no args on a get request" $
        get "/rpc/noparamsproc" `shouldRespondWith`
          [json| "Return value of no parameters procedure." |]
          { matchHeaders = [matchContentTypeJson] }

    it "returns proper output when having the same return col name as the proc name" $ do
      post "/rpc/test" [json|{}|] `shouldRespondWith`
        [json|[{"test":"hello","value":1}]|] { matchHeaders = [matchContentTypeJson] }
      get "/rpc/test" `shouldRespondWith`
        [json|[{"test":"hello","value":1}]|] { matchHeaders = [matchContentTypeJson] }

    context "procs with OUT/INOUT params" $ do
      it "returns a scalar result when there is a single OUT param" $ do
        get "/rpc/single_out_param?num=5" `shouldRespondWith`
          [json|6|] { matchHeaders = [matchContentTypeJson] }
        get "/rpc/single_json_out_param?a=1&b=two" `shouldRespondWith`
          [json|{"a": 1, "b": "two"}|] { matchHeaders = [matchContentTypeJson] }

      it "returns a scalar result when there is a single INOUT param" $
        get "/rpc/single_inout_param?num=2" `shouldRespondWith`
          [json|3|] { matchHeaders = [matchContentTypeJson] }

      it "returns a row result when there are many OUT params" $
        get "/rpc/many_out_params" `shouldRespondWith`
          [json|[{"my_json":{"a": 1, "b": "two"},"num":3,"str":"four"}]|] { matchHeaders = [matchContentTypeJson] }

      it "returns a row result when there are many INOUT params" $
        get "/rpc/many_inout_params?num=1&str=two&b=false" `shouldRespondWith`
          [json| [{"num":1,"str":"two","b":false}]|] { matchHeaders = [matchContentTypeJson] }

    it "can handle procs with args that have a DEFAULT value" $ do
      get "/rpc/many_inout_params?num=1&str=two" `shouldRespondWith`
        [json| [{"num":1,"str":"two","b":true}]|] { matchHeaders = [matchContentTypeJson] }
      get "/rpc/three_defaults?b=4" `shouldRespondWith`
        [json|8|] { matchHeaders = [matchContentTypeJson] }

    it "can map a RAISE error code and message to a http status" $
      get "/rpc/raise_pt402"
        `shouldRespondWith` [json|{ "hint": "Upgrade your plan", "details": "Quota exceeded" }|]
        { matchStatus  = 402
        , matchHeaders = [matchContentTypeJson]
        }

    it "defaults to status 500 if RAISE code is PT not followed by a number" $
      get "/rpc/raise_bad_pt"
        `shouldRespondWith`
        [json|{"hint": null, "details": null}|]
        { matchStatus  = 500
        , matchHeaders = [ matchContentTypeJson ]
        }

    context "expects a single json object" $ do
      it "does not expand posted json into parameters" $
        request methodPost "/rpc/singlejsonparam"
          [("prefer","params=single-object")] [json| { "p1": 1, "p2": "text", "p3" : {"obj":"text"} } |] `shouldRespondWith`
          [json| { "p1": 1, "p2": "text", "p3" : {"obj":"text"} } |]
          { matchHeaders = [matchContentTypeJson] }

      it "accepts parameters from an html form" $
        request methodPost "/rpc/singlejsonparam"
          [("Prefer","params=single-object"),("Content-Type", "application/x-www-form-urlencoded")]
          ("integer=7&double=2.71828&varchar=forms+are+fun&" <>
           "boolean=false&date=1900-01-01&money=$3.99&enum=foo") `shouldRespondWith`
          [json| { "integer": "7", "double": "2.71828", "varchar" : "forms are fun"
                 , "boolean":"false", "date":"1900-01-01", "money":"$3.99", "enum":"foo" } |]
                 { matchHeaders = [matchContentTypeJson] }

      it "works with GET" $
        request methodGet "/rpc/singlejsonparam?p1=1&p2=text" [("Prefer","params=single-object")] ""
          `shouldRespondWith` [json|{ "p1": "1", "p2": "text"}|]
          { matchHeaders = [matchContentTypeJson] }

    it "should work with an overloaded function" $ do
      get "/rpc/overloaded" `shouldRespondWith`
        [json|[{ "overloaded": 1 },
               { "overloaded": 2 },
               { "overloaded": 3 }]|]
        { matchHeaders = [matchContentTypeJson] }
      request methodPost "/rpc/overloaded" [("Prefer","params=single-object")]
        [json|[{"x": 1, "y": "first"}, {"x": 2, "y": "second"}]|]
       `shouldRespondWith`
        [json|[{"x": 1, "y": "first"}, {"x": 2, "y": "second"}]|]
        { matchHeaders = [matchContentTypeJson] }
      get "/rpc/overloaded?a=1&b=2" `shouldRespondWith` [str|3|]
      get "/rpc/overloaded?a=1&b=2&c=3" `shouldRespondWith` [str|"123"|]

    context "only for POST rpc" $ do
      it "gives a parse filter error if GET style proc args are specified" $
        post "/rpc/sayhello?name=John" [json|{}|] `shouldRespondWith` 400

      it "ignores json keys not included in ?columns" $
        post "/rpc/sayhello?columns=name"
          [json|{"name": "John", "smth": "here", "other": "stuff", "fake_id": 13}|]
          `shouldRespondWith`
          [json|"Hello, John"|]
          { matchHeaders = [matchContentTypeJson] }

      it "only takes the first object in case of array of objects payload" $
        post "/rpc/add_them"
          [json|[
            {"a": 1, "b": 2},
            {"a": 4, "b": 6},
            {"a": 100, "b": 200} ]|]
          `shouldRespondWith` "3"
          { matchHeaders = [matchContentTypeJson] }

    context "bulk RPC with params=multiple-objects" $ do
      it "works with a scalar function an returns a json array" $
        request methodPost "/rpc/add_them" [("Prefer", "params=multiple-objects")]
          [json|[
            {"a": 1, "b": 2},
            {"a": 4, "b": 6},
            {"a": 100, "b": 200} ]|]
          `shouldRespondWith`
          [json|
            [3, 10, 300]
          |] { matchHeaders = [matchContentTypeJson] }

      it "works with a scalar function an returns a json array when posting CSV" $
        request methodPost "/rpc/add_them" [("Content-Type", "text/csv"), ("Prefer", "params=multiple-objects")]
          "a,b\n1,2\n4,6\n100,200"
          `shouldRespondWith`
          [json|
            [3, 10, 300]
          |]
          { matchStatus  = 200
          , matchHeaders = [matchContentTypeJson]
          }

      it "works with a non-scalar result" $
        request methodPost "/rpc/get_projects_below?select=id,name" [("Prefer", "params=multiple-objects")]
          [json|[
            {"id": 1},
            {"id": 5} ]|]
          `shouldRespondWith`
          [json|
            [{"id":1,"name":"Windows 7"},
             {"id":2,"name":"Windows 10"},
             {"id":3,"name":"IOS"},
             {"id":4,"name":"OSX"}]
          |] { matchHeaders = [matchContentTypeJson] }

    context "binary output" $ do
      context "Proc that returns scalar" $ do
        it "can query without selecting column" $
          request methodPost "/rpc/ret_base64_bin" (acceptHdrs "application/octet-stream") ""
            `shouldRespondWith` "iVBORw0KGgoAAAANSUhEUgAAAB4AAAAeAQMAAAAB/jzhAAAABlBMVEUAAAD/AAAb/40iAAAAP0lEQVQI12NgwAbYG2AE/wEYwQMiZB4ACQkQYZEAIgqAhAGIKLCAEQ8kgMT/P1CCEUwc4IMSzA3sUIIdCHECAGSQEkeOTUyCAAAAAElFTkSuQmCC"
            { matchStatus = 200
            , matchHeaders = ["Content-Type" <:> "application/octet-stream; charset=utf-8"]
            }

        it "can get raw output with Accept: text/plain" $
          request methodGet "/rpc/welcome" (acceptHdrs "text/plain") ""
            `shouldRespondWith` "Welcome to PostgREST"
            { matchStatus = 200
            , matchHeaders = ["Content-Type" <:> "text/plain; charset=utf-8"]
            }

      context "Proc that returns rows" $ do
        it "can query if a single column is selected" $
          request methodPost "/rpc/ret_rows_with_base64_bin?select=img" (acceptHdrs "application/octet-stream") ""
            `shouldRespondWith` "iVBORw0KGgoAAAANSUhEUgAAAB4AAAAeAQMAAAAB/jzhAAAABlBMVEUAAAD/AAAb/40iAAAAP0lEQVQI12NgwAbYG2AE/wEYwQMiZB4ACQkQYZEAIgqAhAGIKLCAEQ8kgMT/P1CCEUwc4IMSzA3sUIIdCHECAGSQEkeOTUyCAAAAAElFTkSuQmCCiVBORw0KGgoAAAANSUhEUgAAAB4AAAAeAQMAAAAB/jzhAAAABlBMVEX///8AAP94wDzzAAAAL0lEQVQIW2NgwAb+HwARH0DEDyDxwAZEyGAhLODqHmBRzAcn5GAS///A1IF14AAA5/Adbiiz/0gAAAAASUVORK5CYII="
            { matchStatus = 200
            , matchHeaders = ["Content-Type" <:> "application/octet-stream; charset=utf-8"]
            }

        it "fails if a single column is not selected" $
          request methodPost "/rpc/ret_rows_with_base64_bin" (acceptHdrs "application/octet-stream") ""
            `shouldRespondWith`
            [json| {"message":"application/octet-stream requested but more than one column was selected"} |]
            { matchStatus = 406
            , matchHeaders = [matchContentTypeJson]
            }

    context "only for GET rpc" $ do
      it "should fail on mutating procs" $ do
        get "/rpc/callcounter" `shouldRespondWith` 500
        get "/rpc/setprojects?id_l=1&id_h=5&name=FreeBSD" `shouldRespondWith` 500

      it "should filter a proc that has arg name = filter name" $
        get "/rpc/get_projects_below?id=5&id=gt.2&select=id" `shouldRespondWith`
          [json|[{ "id": 3 }, { "id": 4 }]|]
          { matchHeaders = [matchContentTypeJson] }

      it "should work with filters that have the not operator" $ do
        get "/rpc/get_projects_below?id=5&id=not.gt.2&select=id" `shouldRespondWith`
          [json|[{ "id": 1 }, { "id": 2 }]|]
          { matchHeaders = [matchContentTypeJson] }
        get "/rpc/get_projects_below?id=5&id=not.in.(1,3)&select=id" `shouldRespondWith`
          [json|[{ "id": 2 }, { "id": 4 }]|]
          { matchHeaders = [matchContentTypeJson] }

      it "should work with filters that use the plain with language fts operator" $ do
        get "/rpc/get_tsearch?text_search_vector=fts(english).impossible" `shouldRespondWith`
          [json|[{"text_search_vector":"'fun':5 'imposs':9 'kind':3"}]|]
          { matchHeaders = [matchContentTypeJson] }
        get "/rpc/get_tsearch?text_search_vector=plfts.impossible" `shouldRespondWith`
          [json|[{"text_search_vector":"'fun':5 'imposs':9 'kind':3"}]|]
          { matchHeaders = [matchContentTypeJson] }
        get "/rpc/get_tsearch?text_search_vector=not.fts(english).fun%7Crat" `shouldRespondWith`
          [json|[{"text_search_vector":"'amus':5 'fair':7 'impossibl':9 'peu':4"},{"text_search_vector":"'art':4 'spass':5 'unmog':7"}]|]
          { matchHeaders = [matchContentTypeJson] }
        when (actualPgVersion >= pgVersion112) $
            get "/rpc/get_tsearch?text_search_vector=wfts.impossible" `shouldRespondWith`
                [json|[{"text_search_vector":"'fun':5 'imposs':9 'kind':3"}]|]
                { matchHeaders = [matchContentTypeJson] }

    it "should work with an argument of custom type in public schema" $
        get "/rpc/test_arg?my_arg=something" `shouldRespondWith`
          [json|"foobar"|]
          { matchHeaders = [matchContentTypeJson] }
