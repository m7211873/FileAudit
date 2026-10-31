using System.Web.Script.Serialization;

namespace NetWatcher
{
    // 轻量 JSON 封装：统一使用系统自带 JavaScriptSerializer，并放宽长度限制
    public static class Json
    {
        public static string Serialize(object o)
        {
            var s = new JavaScriptSerializer();
            s.MaxJsonLength = int.MaxValue;
            s.RecursionLimit = 100;
            return s.Serialize(o);
        }

        public static T Deserialize<T>(string json)
        {
            var s = new JavaScriptSerializer();
            s.MaxJsonLength = int.MaxValue;
            s.RecursionLimit = 100;
            return s.Deserialize<T>(json);
        }
    }
}
