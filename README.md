# Universe Survival

MMORPG-песочница с UDP-сервером на C# и клиентом на Godot.

## Структура

- `server/` — сервер (C#), запуск через `run_server.bat` или `dotnet run`.
- `universesurvival/` — клиент (Godot 4), основной проект.
- `universesurvival/ui/loading_screen.png` - картинка загрузочного экрана клиента.
- `universesurvival/tiles/resources_trees.png` - спрайты ресурсов (деревья).
- `universesurvival/data/resource_types.json` - типы ресурсов (дроп, инструмент, тайлы).
- `server/docs_server.html` - документация по серверу.
- `universesurvival/docs_client.html` - документация по клиенту.
- `server/ver_server.html` и `universesurvival/ver_client.html` - история версий.
- `server/resource_types.json` - типы ресурсов на сервере (RAM-first данные).

## Быстрый старт

1. Запустите сервер: `server/run_server.bat`.
2. Откройте клиент в Godot и запустите сцену `main.tscn`.
