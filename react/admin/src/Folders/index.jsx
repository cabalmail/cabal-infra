import React, { useState, useEffect, useCallback } from 'react';
import useApi from '../hooks/useApi';
import { PERMANENT_FOLDERS, FOLDER_LIST } from '../constants';
import styles from './Folders.module.css';

function Folders({ setMessage, setFolder: setFolderProp }) {
  const api = useApi();
  const [folders, setFolders] = useState([]);
  const [subFolders, setSubFolders] = useState([]);
  const [newFolder, setNewFolder] = useState('');

  const updateFolders = useCallback(() => {
    api.getFolderList().then(data => {
      try {
        localStorage.setItem(FOLDER_LIST, JSON.stringify(data));
      } catch (e) {
        console.log(e);
      }
      const allFolders = [...new Set([
        ...(data.data.folders),
        ...(data.data.sub_folders)
      ])].sort();
      setFolders(allFolders);
      setSubFolders(data.data.sub_folders);
    }).catch(e => {
      console.log(e);
    });
  }, [api]);

  useEffect(() => {
    updateFolders();
  // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  const handleSetFolder = (e) => {
    e.preventDefault();
    setFolderProp(e.target.value);
  };

  const subscribe = (e) => {
    api.subscribeFolder(e.target.dataset.favorite).then(() => {
      localStorage.removeItem(FOLDER_LIST);
      updateFolders();
    });
  };

  const unsubscribe = (e) => {
    api.unsubscribeFolder(e.target.dataset.favorite).then(() => {
      localStorage.removeItem(FOLDER_LIST);
      updateFolders();
    });
  };

  const handleNewClick = (e) => {
    if (newFolder === "") {
      setMessage("Please enter a name in the input box.", true);
      return;
    }
    if (newFolder.includes(".") || newFolder.includes("/")) {
      setMessage("Folder names must not contain '.' or '/'.");
      return;
    }
    api.newFolder(e.target.dataset.parent, newFolder).then(data => {
      const allFolders = [...new Set([
        ...(data.data.folders),
        ...(data.data.sub_folders)
      ])].sort();
      setFolders(allFolders);
      setSubFolders(data.data.sub_folders);
    }).catch(() => {
      setMessage("Unable to create folder.", true);
    });
  };

  const handleDelClick = (e) => {
    api.deleteFolder(e.target.dataset.folder).then(data => {
      const allFolders = [...new Set([
        ...(data.data.folders),
        ...(data.data.sub_folders)
      ])].sort();
      setFolders(allFolders);
      setSubFolders(data.data.sub_folders);
    }).catch(() => {
      setMessage("Unable to delete folder.", true);
    });
  };

  const folderList = folders.map(item => {
    const favorite = subFolders.includes(item) ? (
      <span data-favorite={item} className={`${styles.favorite} ${styles.subscribed}`} onClick={unsubscribe}>&#9733;</span>
    ) : (
      <span data-favorite={item} className={styles.favorite} onClick={subscribe}>&#9734;</span>
    );
    const deleteButton = PERMANENT_FOLDERS.includes(item) ? null : (
      <button
        className={`${styles.folderButton} ${styles.deleteFolder}`}
        data-folder={item}
        onClick={handleDelClick}
        title={`Delete ${item}`}
      >&#128465;&#65039;</button>
    );
    return (
      <li className={styles.folder} id={item} key={item}>
        {favorite}
        <span className={styles.folderName}>{item}</span>
        <button
          className={styles.folderButton}
          data-parent={item}
          onClick={handleNewClick}
          title={`New subfolder of ${item}`}
        >&#128193;</button>
        {deleteButton}
      </li>
    );
  });

  return (
    <div className={styles.folders}>
      <div className={styles.newFolder}>
        <input
          type="text"
          id="new_folder"
          name="new_folder"
          className={styles.newFolderInput}
          value={newFolder}
          onChange={(e) => setNewFolder(e.target.value)}
        />
        <button
          className={styles.newFolderButton}
          data-parent=""
          onClick={handleNewClick}
        >New Top-level Folder</button>
      </div>
      <hr />
      <div id="count">Found: {folders.length} folders</div>
      <ul className={styles.folderList}>
        {folderList}
      </ul>
    </div>
  );
}

export default Folders;
